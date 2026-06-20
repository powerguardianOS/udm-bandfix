# u5gmax-bandfix

Automatically enforce Odido NL band restrictions on the UniFi U5G-Max modem — persistently, from the Cloud Gateway.

> Inspired by [udm-iptv](https://github.com/fabianishere/udm-iptv)

---

## The Problem

Odido NL (formerly T-Mobile NL) publishes a hardware specification for all FWA (Fixed Wireless Access) equipment. It defines exactly which bands must be **active** and which must be permanently **disabled**:

| Radio | Required active bands | Forbidden (must be disabled) |
|-------|----------------------|------------------------------|
| LTE (FDD) | B1, B3, B7 | B8, B20, B28 |
| LTE (TDD) | B38 | — |
| NR5G SA (FDD) | n1, n3, n7 | n8, n20, n28 |
| NR5G SA (TDD) | n38, n78 | — |
| NR5G NSA (FDD) | n1, n3, n7 | n8, n20, n28 |
| NR5G NSA (TDD) | n38, n78 | — |

From the official spec: *"Het is niet toegestaan om deze banden te gebruiken. De banden moeten uitgezet worden in firmware van de apparatuur, en het moet voor klanten onmogelijk worden gemaakt om de banden te activeren via bijvoorbeeld een app of web GUI."*

The U5G-Max (EM9291) supports band selection via `uiwwand-ctl` over SSH, but:

- The UniFi controller intentionally does not expose band steering or band locking options for the U5G-Max — Ubiquiti has stated this is by design, as band selection is considered a carrier-managed setting, not an end-user setting.
- On every adoption or reconfiguration event, the UniFi controller pushes a full radio config to the modem that resets all band selections back to default (all bands enabled). This happens silently in the background.
- The modem API (`uiwwand-ctl`) does support `set-radio-pref`, but this interface is undocumented and not exposed through the UniFi UI. There is no supported way to make band selections persistent through the UI.
- Community requests for band locking in the UniFi forum have been open since 2022 without a committed fix.
- The U5G-Max runs on tmpfs — any config written to it is lost on reboot, and the `/etc/persistent/cfg/` partition has only ~100 bytes free — too small for scripts.

**Result**: every time the Cloud Gateway or U5G-Max reboots, all bands come back and your Odido connection stops working until the bands are manually reset. This means the only way to enforce Odido-required band restrictions is to run an out-of-band script that monitors and corrects the config after the controller resets it.

## WCDMA Recovery

Sometimes the U5G-Max gets stuck on 3G (WCDMA/UMTS) even when 4G/5G coverage is available. This happens after reboots or when the controller pushes a config reset that disrupts the active radio mode. u5gmax-bandfix detects this automatically via `get-radio-status` on every run. If WCDMA is detected, it sends a mode override (`5gnr,lte`) to kick the modem back to 4G/5G, waits 60 seconds for reregistration, then checks if it succeeded. If the modem is still on WCDMA after 60s, the band fix is skipped for that run and the cron will retry the next hour — this prevents hammering the modem with repeated resets. The event is logged as `"WCDMA detected — forcing reregistration"` in the log file.

## How it Works

u5gmax-bandfix runs as a cron job **on the Cloud Gateway** (not on the modem). Every hour it:

1. Looks up the current U5G-Max IP in the UniFi MongoDB database (the IP is a dynamic public 5G WAN address that changes on reboot)
2. Connects over SSH using a persistent key pair stored in `/data/`
3. Reads the current band config via `uiwwand-ctl`
4. Compares it against the exact Odido specification
5. If it doesn't match → applies the correct configuration
6. Verifies the result and logs everything to `/data/u5gmax-bandfix/band-fix.log`

```
Cloud Gateway (/data/ persistent)
│
├── id_ed25519         SSH private key
├── config             SSH user + ICCID
├── band-fix.sh        Runs hourly via cron
└── band-fix.log       Audit log
         │
         │ SSH (key-based, no password)
         ▼
U5G-Max (UMBBE630)
│
└── uiwwand-ctl        Band configuration tool
```

The ICCID of the active SIM is required by `uiwwand-ctl set-radio-pref`. It's read once during install and cached in the config.

## Network Details

| Setting | Value |
|---------|-------|
| APN | `Fwainternet` |
| IP address | Dynamic public IPv4 |
| 3GPP release | Release 16 or higher |
| Connection types | 4G, 5G NSA (option 3X), 5G SA (option 2) |

> **APN note**: If you're using a third-party modem, make sure the APN is set to `Fwainternet`. The U5G-Max configures this automatically from the SIM.

## Tested Environment

| Component | Version |
|-----------|---------|
| Cloud Gateway Fiber firmware | v5.1.15 |
| U5G-Max firmware | 7.4.1.19032 |
| UniFi Network | 10.4.57 |
| ISP | Odido 5G Internet voor Bedrijven (FWA, NL) |

## Requirements

- UniFi Cloud Gateway (UDM Pro, UDM SE, or Cloud Gateway Fiber)
- U5G-Max (model `UMBBE630`) adopted in UniFi Network
- SSH enabled in **UniFi Network → Settings → Advanced → SSH**
- `sshpass` available on the Cloud Gateway (for one-time key install)
- `python3` available on the Cloud Gateway (for JSON parsing)

## Installation

```bash
curl -sSL https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main/install.sh | bash
```

Run as root on the Cloud Gateway. The installer will:

1. Read the SSH username and password from MongoDB (no manual input needed)
2. Detect the U5G-Max IP from MongoDB
3. Generate an SSH key pair at `/data/u5gmax-bandfix/id_ed25519`
4. Copy the public key to the U5G-Max (uses the MongoDB password — one time only)
5. Read the SIM ICCID from the modem and cache it
6. Install `/data/u5gmax-bandfix/band-fix.sh`
7. Create `/etc/cron.d/u5gmax-bandfix` (runs hourly)
8. Apply the fix immediately and show the result

### Local install (from cloned repo)

```bash
git clone https://github.com/royrijpma/u5gmax-bandfix
cd u5gmax-bandfix
bash install.sh
```

## Usage

After installation, type `u5gmax-bandfix` in the shell to open the interactive menu:

```
╔══════════════════════════════════════════════╗
║          u5gmax-bandfix  v1.1.0              ║
║     Odido NL Band Fix — UniFi U5G-Max        ║
╠══════════════════════════════════════════════╣
  U5G-Max IP:  178.x.x.x
  Cron:        active
  Last run:    2026-06-20 09:05:01
  Result:      OK — bands match Odido spec
╠══════════════════════════════════════════════╣
  1) Force band check now
  2) Show current band status
  3) Edit required bands
  4) Show logs
  5) Reinstall SSH key on U5G-Max
  6) Update to latest version
  7) Uninstall
  0) Exit
╚══════════════════════════════════════════════╝
```

### Check logs

```bash
tail -f /data/u5gmax-bandfix/band-fix.log
```

### Run manually

```bash
/data/u5gmax-bandfix/band-fix.sh
```

### Verify band configuration on the modem

```bash
# From the Cloud Gateway
ICCID=$(grep ICCID /data/u5gmax-bandfix/config | cut -d'"' -f2)
U5G_IP=$(mongo --quiet localhost:27117/ace --eval "print(db.device.findOne({model:'UMBBE630'}).ip)")
SSH_USER=$(grep SSH_USER /data/u5gmax-bandfix/config | cut -d'"' -f2)
printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}' "$ICCID" \
  | ssh -i /data/u5gmax-bandfix/id_ed25519 "${SSH_USER}@${U5G_IP}" uiwwand-ctl
```

Expected output (Odido-compliant):

```json
{"result":{"lte_band":"1,3,7,38","nr5g_sa_band":"1,3,7,38,78","nr5g_nsa_band":"1,3,7,38,78"}}
```

## Uninstall

```bash
bash /data/u5gmax-bandfix/uninstall.sh
```

This removes the cron job, all files in `/data/u5gmax-bandfix/`, and the SSH key from the modem. It does **not** revert the band configuration — it will reset to "all" on the next modem reboot anyway.

## Security

- SSH uses ed25519 key-based auth only — no passwords used after install
- The MongoDB SSH password is cached in `/data/u5gmax-bandfix/config` (mode `600`, root-only) to enable self-healing after modem reboots without requiring MongoDB access
- All files in `/data/u5gmax-bandfix/` are root-only (chmod 600 for config and key)
- The fix only runs read/write over SSH — no arbitrary code execution on the modem
- All external input (SSH_USER from MongoDB, IP, ICCID) is strictly validated with regex before use — e.g., `SSH_USER` must match `^[a-zA-Z0-9_-]{1,32}$` or the script aborts
- All values retrieved from the modem are sanitized (stripped of non-printable characters) before logging or further processing
- Temporary files are created in `/data/u5gmax-bandfix/tmp/` (mode `700`) instead of `/tmp/`, preventing world-readable exposure
- `known_hosts` updates are atomic: written to a `.tmp` file and moved into place, eliminating race-condition risks
- Fully POSIX-compliant: avoids bash-specific constructs like `[[ =~ ]]` for compatibility with `/bin/sh`

## License

MIT — see [LICENSE](LICENSE)

## Built with AI

This tool was entirely vibe-coded with [Claude](https://claude.ai) — from architecture to debugging the UCG Fiber cron environment quirks. Every script, fix, and edge case was developed through conversation.

---

*Not affiliated with Ubiquiti or Odido. Use at your own risk.*  
*Band specification source: Odido 5G Internet hardware specificaties en voorwaarden (3GPP Release 16).*