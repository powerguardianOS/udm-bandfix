#!/bin/bash
# u5gmax-bandfix — interactive CLI for managing Odido NL band restrictions
# Installed to /usr/local/sbin/u5gmax-bandfix

set -euo pipefail

VERSION="1.1.0"
DATA_DIR="/data/u5gmax-bandfix"
CONFIG="$DATA_DIR/config"
SSH_KEY="$DATA_DIR/id_ed25519"
KNOWN_HOSTS="$DATA_DIR/known_hosts"
LOG_FILE="$DATA_DIR/band-fix.log"
CRON_FILE="/etc/cron.d/u5gmax-bandfix"
BAND_FIX="$DATA_DIR/band-fix.sh"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; NC='\033[0m'
BOLD='\033[1m'

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { printf "${R}✗ ERROR: %s${NC}\n" "$*" >&2; exit 1; }
pause() { printf "\nPress Enter to continue..."; read -r; }

get_ip() {
    timeout 30 mongo --quiet localhost:27117/ace \
        --eval "print(db.device.findOne({model:'UMBBE630'}).ip)" < /dev/null 2>/dev/null | tr -d '\r\n' || echo ""
}

get_last_run() {
    if [ -f "$LOG_FILE" ]; then
        grep -E "^\[" "$LOG_FILE" | tail -1 | grep -oE '^\[[0-9 :-]+\]' | tr -d '[]' || echo "never"
    else
        echo "never"
    fi
}

get_last_result() {
    [ -f "$LOG_FILE" ] || { printf "—"; return; }
    local line
    line=$(grep -E "\] (OK:|VERIFIED:|ERROR:|WARNING:)" "$LOG_FILE" | tail -1)
    [ -z "$line" ] && { printf "—"; return; }
    if echo "$line" | grep -q "OK:"; then
        printf "${G}✓ Odido-compliant${NC}"
    elif echo "$line" | grep -q "VERIFIED:"; then
        printf "${G}✓ Fixed & verified${NC}"
    elif echo "$line" | grep -q "WARNING: SSH"; then
        printf "${Y}⚠ Modem offline${NC}"
    elif echo "$line" | grep -q "WCDMA"; then
        printf "${Y}⚠ WCDMA recovery${NC}"
    elif echo "$line" | grep -q "timed out\|timeout"; then
        printf "${Y}⚠ MongoDB timeout${NC}"
    elif echo "$line" | grep -q "ERROR:"; then
        printf "${R}✗ Error — see logs${NC}"
    else
        printf "${Y}⚠ Unknown${NC}"
    fi
}

cron_status() {
    if [ -f "$CRON_FILE" ]; then
        local min
        min=$(grep -E "^[0-9]+ \* \* \* \* root /data/u5gmax-bandfix/band-fix" "$CRON_FILE" | awk '{print $1}' | head -1)
        printf 'active (hourly at :%02d)' "${min:-0}"
    else
        echo "NOT INSTALLED"
    fi
}

ssh_opts() {
    echo "-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"
}

load_config() {
    [ -f "$CONFIG" ] || die "Not installed. Run install.sh first."
    # shellcheck source=/dev/null
    source "$CONFIG"
    : "${SSH_USER:?}"
}

# ── Header ────────────────────────────────────────────────────────────────────
print_header() {
    local u5g_ip cron last_run result
    u5g_ip=$(get_ip)
    [ -z "$u5g_ip" ] || [ "$u5g_ip" = "null" ] && u5g_ip="${R}offline${NC}"
    cron=$(cron_status)
    last_run=$(get_last_run)
    result=$(get_last_result)

    clear
    printf "${C}"
    printf '╔══════════════════════════════════════════════╗\n'
    printf '║            u5gmax-bandfix  v%-5s            ║\n' "$VERSION"
    printf '║      Odido NL Band Fix — UniFi U5G-Max       ║\n'
    printf '╠══════════════════════════════════════════════╣\n'
    printf "${NC}"
    printf "  ${W}U5G-Max IP:${NC}  ${u5g_ip}\n"
    printf "  ${W}Cron:${NC}        %s\n" "$cron"
    printf "  ${W}Last run:${NC}    %s\n" "$last_run"
    printf "  ${W}Result:${NC}      ${result}\n"
    printf "${C}"
    printf '╠══════════════════════════════════════════════╣\n'
    printf "${NC}"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
print_menu() {
    printf "  ${W}1)${NC} Force band check now\n"
    printf "  ${W}2)${NC} Show current band status\n"
    printf "  ${W}3)${NC} Edit required bands\n"
    printf "  ${W}4)${NC} Show logs\n"
    printf "  ${W}5)${NC} Reinstall SSH key on U5G-Max\n"
    printf "  ${W}6)${NC} Update to latest version\n"
    printf "  ${W}7)${NC} Uninstall\n"
    printf "  ${W}0)${NC} Exit\n"
    printf "${C}"
    printf '╚══════════════════════════════════════════════╝\n'
    printf "${NC}"
}

# ── Actions ───────────────────────────────────────────────────────────────────

action_force_check() {
    printf "\n${Y}Running band check...${NC}\n\n"
    [ -f "$BAND_FIX" ] || die "band-fix.sh not found at $BAND_FIX"
    bash "$BAND_FIX" && printf "\n${G}✓ Done.${NC}\n" || printf "\n${R}✗ Check failed — see logs.${NC}\n"
    pause
}

action_band_status() {
    load_config
    local u5g_ip iccid current
    u5g_ip=$(get_ip)
    [ -z "$u5g_ip" ] || [ "$u5g_ip" = "null" ] && { printf "\n${R}U5G-Max not found in MongoDB.${NC}\n"; pause; return; }

    printf "\n${Y}Querying U5G-Max band configuration...${NC}\n"

    # Get live ICCID
    iccid=$(printf '{"method":"get-sim-state"}' \
        | ssh $(ssh_opts) "${SSH_USER}@${u5g_ip}" "uiwwand-ctl" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['iccid'])" 2>/dev/null) || iccid="${ICCID_CACHE:-}"

    [ -z "$iccid" ] && { printf "${R}Could not read ICCID.${NC}\n"; pause; return; }

    current=$(printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}' "$iccid" \
        | ssh $(ssh_opts) "${SSH_USER}@${u5g_ip}" "uiwwand-ctl" 2>/dev/null) || \
        { printf "${R}Could not reach U5G-Max via SSH.${NC}\n"; pause; return; }

    printf "\n${W}ICCID:${NC} %s\n\n" "$iccid"

    python3 - "$current" << 'PYEOF'
import json, sys

REQUIRED = {
    "lte_band":      {1, 3, 7, 38},
    "nr5g_sa_band":  {1, 3, 7, 38, 78},
    "nr5g_nsa_band": {1, 3, 7, 38, 78},
}
FORBIDDEN = {8, 20, 28}

GREEN = "\033[0;32m"
RED   = "\033[0;31m"
BOLD  = "\033[1m"
NC    = "\033[0m"

try:
    data = json.loads(sys.argv[1])
    result = data.get("result", {})

    labels = {
        "lte_band":      "LTE bands    ",
        "nr5g_sa_band":  "NR5G SA bands",
        "nr5g_nsa_band": "NR5G NSA bands",
    }

    for key, req in REQUIRED.items():
        val = result.get(key, "")
        actual = {int(b) for b in val.split(",") if b.strip().isdigit()} if val else set()
        forbidden_present = actual & FORBIDDEN
        matches_spec = actual == req

        if matches_spec:
            status = f"{GREEN}✓ Odido-compliant{NC}"
        elif forbidden_present:
            status = f"{RED}✗ FORBIDDEN BANDS ACTIVE: {sorted(forbidden_present)}{NC}"
        else:
            status = f"{RED}✗ Non-compliant{NC}"

        print(f"  {BOLD}{labels[key]}:{NC} {val or '(empty)'}")
        print(f"  {'':15}  → {status}")
        print()
except Exception as e:
    print(f"Parse error: {e}")
PYEOF
    pause
}

action_edit_bands() {
    load_config

    # Odido-required bands (always the baseline)
    local BASE_LTE="1,3,7,38"
    local BASE_SA="1,3,7,38,78"
    local BASE_NSA="1,3,7,38,78"

    printf "\n${Y}Disable extra bands${NC}\n"
    printf "${W}Odido-required active bands (baseline):${NC}\n"
    printf "  LTE:       B%s\n" "$(echo "$BASE_LTE" | sed 's/,/, B/g')"
    printf "  NR5G SA:   n%s\n" "$(echo "$BASE_SA"  | sed 's/,/, n/g')"
    printf "  NR5G NSA:  n%s\n" "$(echo "$BASE_NSA" | sed 's/,/, n/g')"
    printf "\n${Y}Note:${NC} B8/B20/B28 and n8/n20/n28 are always disabled (Odido requirement).\n"
    printf "Enter band numbers to additionally disable from the baseline (leave empty for none).\n\n"

    read -r -p "Disable from LTE  (e.g. 38 to disable B38):   " DISABLE_LTE
    read -r -p "Disable from NR5G (e.g. 78 to disable n78):   " DISABLE_NR

    # Compute result: remove disabled bands from baseline
    _remove_bands() {
        local list="$1" remove="$2"
        local result=""
        local b
        IFS=',' read -ra bands <<< "$list"
        for b in "${bands[@]}"; do
            b="${b// /}"
            if ! echo ",$remove," | grep -q ",$b,"; then
                result="${result:+$result,}$b"
            fi
        done
        printf '%s' "$result"
    }

    INPUT_LTE=$(_remove_bands "$BASE_LTE" "$DISABLE_LTE")
    INPUT_SA=$(_remove_bands  "$BASE_SA"  "$DISABLE_NR")
    INPUT_NSA=$(_remove_bands "$BASE_NSA" "$DISABLE_NR")

    [ -z "$INPUT_LTE" ] && { printf "${R}✗ Cannot disable all LTE bands.${NC}\n"; pause; return; }
    [ -z "$INPUT_SA" ]  && { printf "${R}✗ Cannot disable all NR5G SA bands.${NC}\n"; pause; return; }
    [ -z "$INPUT_NSA" ] && { printf "${R}✗ Cannot disable all NR5G NSA bands.${NC}\n"; pause; return; }

    printf "\n${W}Result:${NC}\n"
    printf "  LTE:      %s\n" "$INPUT_LTE"
    printf "  NR5G SA:  %s\n" "$INPUT_SA"
    printf "  NR5G NSA: %s\n" "$INPUT_NSA"
    read -r -p "Apply? [y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { printf "Cancelled.\n"; pause; return; }

    # Write custom bands to config
    {
        grep -v "^CUSTOM_LTE\|^CUSTOM_SA\|^CUSTOM_NSA" "$CONFIG"
        printf 'CUSTOM_LTE="%s"\n' "$INPUT_LTE"
        printf 'CUSTOM_SA="%s"\n' "$INPUT_SA"
        printf 'CUSTOM_NSA="%s"\n' "$INPUT_NSA"
    } > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    chmod 600 "$CONFIG"

    # Patch band-fix.sh to use custom values
    sed -i \
        -e "s|^LTE_REQUIRED=.*|LTE_REQUIRED=\"$INPUT_LTE\"|" \
        -e "s|^NR5G_SA_REQUIRED=.*|NR5G_SA_REQUIRED=\"$INPUT_SA\"|" \
        -e "s|^NR5G_NSA_REQUIRED=.*|NR5G_NSA_REQUIRED=\"$INPUT_NSA\"|" \
        "$BAND_FIX"

    printf "\n${G}✓ Bands updated. Running force check...${NC}\n"
    bash "$BAND_FIX" && printf "\n${G}✓ Applied.${NC}\n" || printf "\n${R}✗ Check failed — see logs.${NC}\n"
    pause
}

action_show_logs() {
    printf "\n${Y}Last 50 lines of %s:${NC}\n\n" "$LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
        tail -50 "$LOG_FILE"
    else
        printf "(no log file yet)\n"
    fi
    printf "\n"
    read -r -p "Follow log live? [y/N] " FOLLOW
    if [[ "$FOLLOW" =~ ^[Yy]$ ]]; then
        printf "${Y}Ctrl+C to stop.${NC}\n\n"
        tail -f "$LOG_FILE"
    fi
}

action_reinstall_key() {
    load_config
    local u5g_ip ssh_pass
    u5g_ip=$(get_ip)
    [ -z "$u5g_ip" ] || [ "$u5g_ip" = "null" ] && { printf "\n${R}U5G-Max not online.${NC}\n"; pause; return; }

    printf "\n${Y}Reinstalling SSH key on U5G-Max ($u5g_ip)...${NC}\n"
    printf "Reading password from MongoDB...\n"
    ssh_pass=$(timeout 30 mongo --quiet localhost:27117/ace \
        --eval "print(db.setting.findOne({key:'mgmt'}).x_ssh_password)" < /dev/null 2>/dev/null | tr -d '\r\n') || true
    [ -z "$ssh_pass" ] || [ "$ssh_pass" = "null" ] && { printf "${R}Could not read password from MongoDB.${NC}\n"; pause; return; }

    # Re-scan host key (IP may have changed)
    ssh-keyscan -T 10 "$u5g_ip" > "$KNOWN_HOSTS" 2>/dev/null || true

    _PASS_FILE=$(mktemp /tmp/.udm-sshpass-XXXXXX)
    chmod 600 "$_PASS_FILE"
    printf '%s' "$ssh_pass" > "$_PASS_FILE"

    sshpass -f "$_PASS_FILE" ssh-copy-id \
        -i "$SSH_KEY.pub" \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${u5g_ip}" 2>/dev/null && \
        printf "${G}✓ SSH key reinstalled.${NC}\n" || \
        printf "${R}✗ Failed — check connectivity.${NC}\n"

    rm -f "$_PASS_FILE"
    printf '%s\n' "$u5g_ip" > "$DATA_DIR/last_ip.txt"
    pause
}

action_update() {
    local BASE="https://raw.githubusercontent.com/royrijpma/u5gmax-bandfix/main"
    local ok=0 fail=0

    printf "\n${Y}Updating all u5gmax-bandfix scripts from GitHub...${NC}\n\n"

    if ! command -v curl >/dev/null 2>&1; then
        printf "${R}curl not available.${NC}\n"; pause; return
    fi

    _update_file() {
        local url="$1" dest="$2" mode="$3"
        if curl -sSL "$url" -o "$dest.new" && mv "$dest.new" "$dest" && chmod "$mode" "$dest"; then
            printf "  ${G}✓${NC} %s\n" "$dest"
            ok=$((ok+1))
        else
            rm -f "$dest.new"
            printf "  ${R}✗${NC} %s\n" "$dest"
            fail=$((fail+1))
        fi
    }

    _update_file "$BASE/band-fix.sh"    "$DATA_DIR/band-fix.sh"    "+x"
    _update_file "$BASE/on-boot.sh"     "$DATA_DIR/on-boot.sh"     "+x"
    _update_file "$BASE/uninstall.sh"   "$DATA_DIR/uninstall.sh"   "+x"
    _update_file "$BASE/u5gmax-bandfix.sh" "/usr/local/sbin/u5gmax-bandfix" "+x"

    printf "\n"
    if [ "$fail" -eq 0 ]; then
        printf "${G}✓ All scripts updated.${NC}\n"
        exit 0
    else
        printf "${Y}⚠ %d updated, %d failed.${NC}\n" "$ok" "$fail"
        pause
    fi
}

action_uninstall() {
    printf "\n${R}${BOLD}WARNING: This will remove u5gmax-bandfix completely.${NC}\n"
    printf "The U5G-Max will revert to all-bands on next reboot.\n\n"
    read -r -p "Type 'yes' to confirm: " CONFIRM
    [ "$CONFIRM" = "yes" ] || { printf "Cancelled.\n"; pause; return; }

    local UNINSTALL
    UNINSTALL="$(dirname "$BAND_FIX")/uninstall.sh"
    # Try local uninstall.sh first, then fall back to same dir as this script
    [ -f "$UNINSTALL" ] || UNINSTALL="/usr/local/sbin/u5gmax-bandfix-uninstall"

    if [ -f "$UNINSTALL" ]; then
        bash "$UNINSTALL"
        rm -f /usr/local/sbin/u5gmax-bandfix
        printf "\n${G}Done. u5gmax-bandfix removed.${NC}\n"
        exit 0
    else
        printf "${R}Uninstall script not found at %s${NC}\n" "$UNINSTALL"
        pause
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
# Non-interactive mode: u5gmax-bandfix check|status|logs|update|uninstall
if [ $# -gt 0 ]; then
    case "$1" in
        check)     action_force_check ;;
        status)    action_band_status ;;
        logs)      action_show_logs ;;
        update)    action_update ;;
        uninstall) action_uninstall ;;
        *)
            printf "Usage: u5gmax-bandfix [check|status|logs|update|uninstall]\n"
            printf "       u5gmax-bandfix          (interactive menu)\n"
            exit 1
            ;;
    esac
    exit 0
fi

# Interactive menu
while true; do
    print_header
    print_menu
    printf "\n  ${W}Choose:${NC} "
    read -r CHOICE

    case "$CHOICE" in
        1) action_force_check ;;
        2) action_band_status ;;
        3) action_edit_bands ;;
        4) action_show_logs ;;
        5) action_reinstall_key ;;
        6) action_update ;;
        7) action_uninstall ;;
        0) clear; exit 0 ;;
        *) printf "\n${R}Invalid choice.${NC}\n"; sleep 1 ;;
    esac
done
