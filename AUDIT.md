# udm-bandfix Audit Report
> Datum: 2026-06-16 15:36
> Model: gemma4:31b-cloud
> Geen Claude tokens gebruikt.

---
## Security Audit

Als security auditor heb ik de scripts geanalyseerd. Over het algemeen is dit script zeer zorgvuldig geschreven voor een Bash-implementatie; er is veel aandacht besteed aan inputvalidatie en het voorkomen van klassieke shell-injecties.

Toch zijn er enkele kwetsbaarheden, voornamelijk gerelateerd aan het feit dat het script als `root` draait en interacteert met externe data.

### 1. KRITIEK: Onveilige `sed` in-place edit (Command Injection)
In `band-fix.sh` wordt de ICCID in de config bijgewerkt met `sed -i "s/^ICCID_CACHE=.*/ICCID_CACHE=\"$ICCID\"/" "$CONFIG"`.
Hoewel de `$ICCID` variabele vooraf wordt gevalideerd met een regex (`^[0-9]{18,20}$`), is dit een gevaarlijk patroon. Mocht de validatie-logica ooit worden versoepeld of omzeild (bijv. door een fout in een update), dan kan een aanvaller via de MongoDB-database volledige root-access krijgen op de Cloud Gateway door shell-metacharacters in de ICCID te plaatsen.
*   **Fix:** Gebruik een tijdelijk bestand of een tool als `jq` (indien config JSON was). Beter nog: gebruik een delimiter die niet in de data voorkomt, of schrijf het bestand volledig opnieuw via een heredoc.

### 2. HOOG: Potentiële Race Condition / Symlink Attack in `/data`
Het script maakt gebruik van `$TMP_DIR` en vaste bestandsnamen in `/data/udm-bandfix`. Omdat het script als root draait, kan een lokale gebruiker met beperkte rechten (indien aanwezig op de UDM) proberen een symlink te plaatsen van `/data/udm-bandfix/tmp/known_hosts.tmp` naar bijvoorbeeld `/etc/shadow`. Wanneer het script `mv` of `printf` uitvoert, overschrijft root onbedoeld systeemfiles.
*   **Fix:** Gebruik `mktemp` voor **alle** tijdelijke bestanden (zoals al gedeeltelijk gedaan in `install.sh`) in plaats van voorspelbare namen zoals `known_hosts.tmp`.

### 3. MEDIUM: Insecure `mongo --eval` (Injection risk)
De queries worden uitgevoerd als: `mongo --eval "print(db.device.findOne({model:'UMBBE630'}).ip)"`.
Hoewel de input hier statisch is (`'UMBBE630'`), is het gebruik van `--eval` met dubbele quotes in Bash riskant. Als de query ooit variabelen zou bevatten, is dit een direct injectiepunt voor JavaScript-executie in de MongoDB shell.
*   **Fix:** Gebruik een script-bestand voor de MongoDB query of gebruik de `--eval` optie met enkelvoudige quotes `'` om shell-expansie te voorkomen.

### 4. MEDIUM: SSH Host Key Trust-on-First-Use (TOFU)
In `install.sh` en `band-fix.sh` wordt `ssh-keyscan` gebruikt om de host key op te halen en direct in `known_hosts` te zetten. Dit is een vorm van "blind trust". Een Man-in-the-Middle (MitM) tijdens de eerste scan kan een kwaadaardige key injecteren, waarna alle volgende communicatie versleuteld is met de key van de aanvaller.
*   **Fix:** Dit is lastig in automatisering, maar de juiste methode is het handmatig verifiëren van de fingerprint of het pushen van de publieke key van het modem via een veilige Out-of-Band methode.

### 5. MEDIUM: Log Injection
De functie `strip_nonprintable` verwijdert niet-printbare tekens, maar staat nieuwe regels (`\n`) en carriage returns (`\r`) mogelijk toe (afhankelijk van de locale `[:print:]` definitie). Een aanvaller die controle heeft over de ICCID of IP in MongoDB kan "fake" log-entries genereren om auditors te misleiden.
*   **Fix:** Gebruik `tr -d '\r\n'` expliciet in de `log()` functie om te garanderen dat één log-aanroep altijd exact één regel in het bestand produceert.

### 6. LAAG: SSH Password in Geheugen (Sleutels)
Hoewel `sshpass -f "$_PASS_FILE"` wordt gebruikt om het wachtwoord uit de proceslijst (`ps aux`) te houden, blijft het wachtwoord in plaintext op de schijf staan in een temp-file gedurende enkele milliseconden. In een zeer strikte omgeving is dit een risico.
*   **Fix:** Gebruik een named pipe (FIFO) of voer het wachtwoord direct via stdin naar `sshpass` als dat mogelijk is zonder bestand.

### 7. LAAG: Overmatige Privileges
Het script draait volledig als `root`. Voor het uitvoeren van SSH-commando's en het schrijven naar `/data` is root-privilege niet strikt noodzakelijk voor het gehele proces.
*   **Fix:** Creëer een specifieke service-user `udm-bandfix` die eigenaar is van `/data/udm-bandfix` en voer het script onder deze gebruiker uit via cron.

### Samenvatting van de Security Posture
| Risico | Score | Impact | Waarschijnlijkheid |
| :--- | :--- | :--- | :--- |
| `sed` Injection | **Kritiek** | Full Root Compromise | Laag (door validatie) |
| Symlink Attack | **Hoog** | Systeemcorruptie/PrivEsc | Medium |
| MitM SSH Scan | **Medium** | Data Interceptie | Medium |
| Log Injection | **Laag** | Audit Log Manipulatie | Medium |

**Eindoordeel:** De auteur heeft duidelijk verstand van security (gebruik van `set -euo pipefail`, `StrictHostKeyChecking=yes`, en regex validatie). De meest urgente actie is het vervangen van de `sed -i` bewerking door een veiligere methode om "defense in depth" te garanderen.

---
## Code Audit

Dit is een zeer solide implementatie. De auteur heeft duidelijk rekening gehouden met security (input validatie, SSH-hardening) en robuustheid (singleton lock, atomic updates).

Hier zijn de belangrijkste bevindingen voor een verdere professionalisering:

### 1. Portabiliteit: Bash-ism vs BusyBox/ash (HOOG)
**Bevinding:** De scripts gebruiken `#!/bin/bash` en Bash-specifieke features zoals `[[` (impliciet via `grep` maar ook `source`), `set -euo pipefail`, en `<<<` (here-strings). Veel UniFi-omgevingen/Cloud Gateways gebruiken BusyBox `ash`. Als `/bin/bash` niet aanwezig is, falen de scripts direct.
**Refactor:** 
* Controleer of `bash` standaard aanwezig is op het doelplatform. Zo niet: gebruik `#!/bin/sh` en vervang `set -euo pipefail` door `set -eu`.
* Vervang `while ... done <<< "$MISMATCHES"` door `echo "$MISMATCHES" | while read -r line; do ... done`.

### 2. MongoDB Afhankelijkheid & Time-outs (MEDIUM)
**Bevinding:** De `mongo` CLI-aanroep heeft geen timeout. Als de MongoDB-service hangt of traag reageert, blokkeert het script (en eventueel de cron-job) onbeperkt.
**Refactor:** Gebruik de `timeout` utility:
`U5G_IP=$(timeout 10s mongo --quiet ...)`

### 3. Idempotentie: Config File Mutatie (MEDIUM)
**Bevinding:** In `band-fix.sh` wordt de config file met `sed -i` aangepast om `ICCID_CACHE` bij te werken. Dit is riskant als het script crasht tijdens het schrijven, en het is ongebruikelijk voor een "runtime" script om zijn eigen configuratiebestand permanent te wijzigen.
**Refactor:** Sla de `ICCID_CACHE` op in een apart bestand in `$DATA_DIR/cache_iccid` in plaats van de hoofdconfiguratie te muteren.

### 4. Foutafhandeling: Python JSON parsing (MEDIUM)
**Bevinding:** De Python-snippets gebruiken `sys.argv[1]` voor JSON-input. Bij zeer grote JSON-outputs (hoewel onwaarschijnlijk hier) kan dit leiden tot "Argument list too long". Bovendien is de foutafhandeling in de Python-blokken beperkt tot een `print` naar stderr.
**Refactor:** Gebruik `sys.stdin.read()` in plaats van `sys.argv[1]` en stuur de JSON via een pipe (`| python3 ...`).

### 5. Hardcoded MongoDB Poort/Database (LAAG)
**Bevinding:** `localhost:27117/ace` is overal hardcoded. Hoewel dit standaard is voor UniFi, maakt het migratie of updates naar nieuwe versies lastiger.
**Refactor:** Verplaats `MONGO_HOST="localhost:27117"` en `MONGO_DB="ace"` naar de `config` file.

### 6. SSH Verbositeit & Logging (LAAG)
**Bevinding:** SSH-fouten worden grotendeels onderdrukt via `2>/dev/null`. Bij een echt probleem (bijv. "Permission denied" vs "Connection timeout") is het logboek nu te summier ("SSH failed").
**Refactor:** Redirect stderr naar een tijdelijk bestand of een variabele bij kritieke stappen, zodat `die` de exacte SSH-foutmelding kan loggen.

### 7. Installatie: `sshpass` Security (LAAG)
**Bevinding:** Hoewel er een temp-file wordt gebruikt voor het wachtwoord (wat goed is), blijft `sshpass` een extern pakket dat in plaintext in het geheugen werkt.
**Refactor:** Gezien de context van een Cloud Gateway is dit acceptabel, maar een melding in de log dat `sshpass` wordt gebruikt voor de initiële setup is wenselijk.

### 8. On-boot race condition (LAAG)
**Bevinding:** De cron `@reboot` start `on-boot.sh`. Er is een kans dat het netwerk of de MongoDB-service nog niet volledig geïnitialiseerd is wanneer het script start.
**Refactor:** Zorg dat `on-boot.sh` een retry-loop heeft met een exponentiële back-off voordat het de eerste keer `band-fix.sh` aanroept.

---

**Eindoordeel:** De code is van zeer hoge kwaliteit. De meest kritieke actie is het verifiëren van de shell-omgeving (`bash` vs `ash`). Indien `bash` gegarandeerd aanwezig is, zijn de overige punten voornamelijk "polishing".

---
## QA / Edge Cases

Als QA Engineer heb ik de scripts geanalyseerd. De scripts zijn zeer robuust geschreven (met `set -euo pipefail`, input validatie en singleton locks), maar er zijn enkele kritieke zwakheden in de interactie tussen de Cloud Gateway (CGW) en het modem.

Hier is de analyse van de edge cases:

---

### 1. Reboot van de modem halverwege een fix
*   **Wat gebeurt er:** De SSH-connectie wordt abrupt verbroken. Omdat `set -e` is actief, zal het script direct `die` aanroepen zodra de SSH-sessie faalt tijdens het sturen van de payload of het verifiëren.
*   **Afgehandeld?** Gedeeltelijk. De `LOCK_DIR` wordt via `trap` netjes opgeruimd, maar de modem kan in een inconsistente state achterblijven (hoewel onwaarschijnlijk bij een reboot).
*   **Ernst:** **MEDIUM**. De fix mislukt deze keer, maar de volgende cronjob (over een uur) herstelt dit.
*   **Fix:** Voeg een retry-mechanisme toe rondom de `ssh` calls in `band-fix.sh` of accepteer dat de hourly cron dit oplost.

### 2. Modem firmware change (get-radio-pref format)
*   **Wat gebeurt er:** De Python-parser in `check_compliance` verwacht specifieke JSON-keys (`lte_band`, etc.). Als de firmware de output verandert naar bijv. `lte_bands` (meervoud) of een andere structuur, gooit Python een `KeyError`.
*   **Afgehandeld?** Ja. De `try...except` blok in de Python-sectie vangt dit op en logt de raw input naar `stderr`, waarna het script via `sys.exit(1)` stopt.
*   **Ernst:** **MEDIUM**. De fix stopt met werken totdat het script wordt geüpdatet.
*   **Fix:** Implementeer "soft-fail" logging waarbij het script melding maakt van een "Firmware Version Mismatch" in plaats van een generieke Parse Error.

### 3. ICCID verandert (SIM-swap)
*   **Wat gebeurt er:** Het script haalt de ICCID live op via `get-sim-state`. Als deze verschilt van de `ICCID_CACHE`, update het script de config file en gebruikt de nieuwe ICCID voor de band-fix.
*   **Afgehandeld?** **Ja, uitstekend.** Dit is een sterk punt in het ontwerp.
*   **Ernst:** **LAAG**.
*   **Fix:** Geen actie nodig.

### 4. MongoDB tijdelijk down
*   **Wat gebeurt er:** De call `mongo --quiet ...` faalt. Omdat het script `set -e` gebruikt en de output wordt gecontroleerd op `null` of leeg, zal het script direct `die` aanroepen.
*   **Afgehandeld?** Ja, het script stopt veilig.
*   **Ernst:** **MEDIUM**. De band-fix draait niet.
*   **Fix:** Sla het laatst bekende IP adres op in `$LAST_IP_FILE` en gebruik dit als fallback als MongoDB onbereikbaar is, in plaats van direct te `die`.

### 5. Crontab verdwijnt na firmware-update CGW
*   **Wat gebeurt er:** UniFi updates overschrijven vaak `/etc/cron.d/`. De hourly job verdwijnt.
*   **Afgehandeld?** Gedeeltelijk. De `install.sh` installeert een `@reboot` job. Als `/etc/cron.d/` volledig wordt gewist, is alles weg. Als alleen de hourly job gaat, blijft de `@reboot` job (indien deze in een ander bestand staat of overleeft) mogelijk actief.
*   **Ernst:** **HOOG**. De band-fix stopt permanent zonder dat de gebruiker het merkt.
*   **Fix:** De `on-boot.sh` zou een check moeten bevatten: *"Bestaat de hourly cronjob nog? Zo nee, voeg hem opnieuw toe aan /etc/cron.d/udm-bandfix"*.

### 6. SSH key op modem verdwijnt (firmware wipe)
*   **Wat gebeurt er:** `ssh $SSH_OPTS ... "exit 0"` faalt. Het script logt een WARNING en doet een `exit 0`.
*   **Afgehandeld?** Ja, het script crasht niet en blokkeert de lock niet.
*   **Ernst:** **MEDIUM**. De fix werkt niet meer. De gebruiker moet `install.sh` handmatig opnieuw draaien.
*   **Fix:** Automatiseer het herstel. Als SSH faalt, probeer dan (via een beveiligde methode) de public key opnieuw te pushen met `sshpass` (hiervoor moet het wachtwoord in de config staan, wat een veiligheidsrisico is).

### 7. /data/ volume vol (logs)
*   **Wat gebeurt er:** `rotate_log` beperkt de log tot 512KB. Echter, als de disk *volledig* vol is, faalt `mkdir -p "$TMP_DIR"` of het schrijven van de `.lock`.
*   **Afgehandeld?** De log-rotatie voorkomt dat het script *zelf* de disk vult. Maar als andere processen de disk vullen, faalt het script.
*   **Ernst:** **LAAG**.
*   **Fix:** Gebruik `mktemp` in `/tmp` (ramdisk) voor tijdelijke JSON-bestanden in plaats van `/data/udm-bandfix/tmp` om write-failures op de flash-storage te verminderen.

### 8. Concurrency (twee cronjobs tegelijk)
*   **Wat gebeurt er:** De tweede instantie probeert `mkdir "$LOCK_DIR"` uit te voeren. Dit faalt omdat de map al bestaat.
*   **Afgehandeld?** **Ja, perfect.** De `mkdir` actie is atomair in Linux.
*   **Ernst:** **LAAG**.
*   **Fix:** Geen actie nodig.

### 9. sshpass niet beschikbaar op CGW
*   **Wat gebeurt er:** Alleen relevant tijdens `install.sh`. Het script probeert `apt-get install -y sshpass`. Als dit faalt (bijv. geen internet), geeft het script een `die`.
*   **Afgehandeld?** Ja.
*   **Ernst:** **LAAG** (gebeurt alleen bij installatie).
*   **Fix:** Geen actie nodig.

### 10. MongoDB query geeft 'null' (device niet adopted)
*   **Wat gebeurt er:** `U5G_IP` wordt `"null"`. De check `[ "$U5G_IP" = "null" ]` triggert en het script voert `die` uit.
*   **Afgehandeld?** Ja.
*   **Ernst:** **MEDIUM**. Het script stopt.
*   **Fix:** Geen actie nodig, aangezien het modem zonder adoptie sowieso niet beheersbaar is via de CGW.

---

### Samenvattend Advies voor de Ontwikkelaar:
De grootste risico's zijn **firmware updates van de CGW (cron loss)** en **MongoDB downtime**.

**Prioriteit 1:** Update `on-boot.sh` zodat deze de `/etc/cron.d/udm-bandfix` file herstelt als deze ontbreekt.
**Prioriteit 2:** Implementeer een IP-fallback in `band-fix.sh` zodat hij niet afhankelijk is van MongoDB bij elke run (gebruik `$LAST_IP_FILE`).
**Prioriteit 3:** Verplaats `$TMP_DIR` naar `/tmp` om slijtage van de flash-storage te beperken en crashes bij een volle `/data` partitie te voorkomen.

---
## Samenvatting

Hier is de beknopte samenvatting van het audit rapport voor **udm-bandfix**:

### Samenvatting
Het script is van hoge kwaliteit, robuust geschreven en vertoont veel aandacht voor inputvalidatie en foutafhandeling. De algemene security-posture is goed, maar er zijn risico's aanwezig doordat het script als `root` draait en afhankelijk is van externe data en MongoDB. De belangrijkste verbeterpunten liggen bij "defense in depth" (voorkomen van privilege escalation), portabiliteit (Bash vs. Ash) en persistentie na firmware-updates.

**Totaal bevindingen per ernst:**
*   **Kritiek:** 1 (Command Injection via `sed`)
*   **Hoog:** 2 (Symlink attack, Bash-portabiliteit)
*   **Medium:** 7 (MongoDB injection, MitM SSH, Log injection, timeouts, etc.)
*   **Laag:** 6 (SSH-wachtwoorden in geheugen, overmatige privileges, etc.)

### Top 3 kritieke acties voor de auteur:
1.  **Beveilig de config-update:** Vervang de onveilige `sed -i` bewerking door een veiligere methode (zoals een tijdelijk bestand of heredoc) om volledige root-compromis via command injection te voorkomen.
2.  **Garandeer persistentie:** Update `on-boot.sh` om de hourly cronjob in `/etc/cron.d/udm-bandfix` automatisch te herstellen als deze na een firmware-update van de Cloud Gateway is verdwenen.
3.  **Verifieer Shell-omgeving:** Controleer of `/bin/bash` gegarandeerd aanwezig is op het doelplatform; zo niet, refactor het script naar `#!/bin/sh` (BusyBox/ash) om directe crashes te voorkomen.
