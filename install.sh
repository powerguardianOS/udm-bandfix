#!/bin/bash
# udm-bandfix installer
# Usage: curl -sSL https://raw.githubusercontent.com/powerguardianOS/udm-bandfix/main/install.sh | bash

set -euo pipefail

DATA_DIR="/data/udm-bandfix"
CONFIG="$DATA_DIR/config"
SSH_KEY="$DATA_DIR/id_ed25519"
KNOWN_HOSTS="$DATA_DIR/known_hosts"
LOG_FILE="$DATA_DIR/band-fix.log"
CRON_FILE="/etc/cron.d/udm-bandfix"
SCRIPT_SRC="https://raw.githubusercontent.com/powerguardianOS/udm-bandfix/main/src/band-fix.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

msg()  { printf '%b%s%b\n' "$BOLD" "$*" "$NC"; }
ok()   { printf '%b✓ %s%b\n' "$GREEN" "$*" "$NC"; }
warn() { printf '%b⚠ %s%b\n' "$YELLOW" "$*" "$NC"; }
die()  { printf '%b✗ ERROR: %s%b\n' "$RED" "$*" "$NC" >&2; exit 1; }

# Cleanup temp files on exit
_TMP_DIR="$DATA_DIR/tmp"
_PASS_FILE=""
trap '[ -n "$_PASS_FILE" ] && rm -f "$_PASS_FILE"; [ -d "$_TMP_DIR" ] && rmdir "$_TMP_DIR" 2>/dev/null || true' EXIT

msg ""
msg "=== udm-bandfix installer ==="
msg ""

# --- Prerequisite checks ---
[ "$(id -u)" -eq 0 ] || die "Must run as root"
command -v mongo   >/dev/null 2>&1 || die "mongo client not found"
command -v ssh     >/dev/null 2>&1 || die "ssh not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

if ! command -v sshpass >/dev/null 2>&1; then
    warn "sshpass not found — attempting install..."
    apt-get install -y sshpass 2>/dev/null || \
        die "sshpass not found and could not install it. Run: apt-get install sshpass"
fi

mkdir -p "$DATA_DIR"
touch "$DATA_DIR/.write_test" 2>/dev/null || die "Cannot write to $DATA_DIR (check /data mount)"
rm -f "$DATA_DIR/.write_test"

# --- Validate IP helper ---
validate_ip() {
    local ip="$1"
    echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || \
        die "Invalid IP address from MongoDB: '$ip'"
}

# --- Validate SSH username helper ---
validate_ssh_user() {
    local user="$1"
    echo "$user" | grep -qE '^[a-zA-Z0-9_-]{1,32}$' || \
        die "Invalid SSH username: '$user'"
}

# --- Retrieve SSH credentials from MongoDB ---
msg "Reading SSH credentials from UniFi MongoDB..."
SSH_USER=$(mongo --quiet localhost:27117/ace \
    --eval "print(db.setting.findOne({key:'mgmt'}).x_ssh_username)" 2>/dev/null | tr -d '\r\n') || true
SSH_PASS=$(mongo --quiet localhost:27117/ace \
    --eval "print(db.setting.findOne({key:'mgmt'}).x_ssh_password)" 2>/dev/null | tr -d '\r\n') || true

[ -z "$SSH_USER" ] || [ "$SSH_USER" = "null" ] && \
    die "Could not read SSH username from MongoDB. Is SSH enabled in UniFi Network?"
[ -z "$SSH_PASS" ] || [ "$SSH_PASS" = "null" ] && \
    die "Could not read SSH password from MongoDB"

# Validate SSH_USER
validate_ssh_user "$SSH_USER"
ok "SSH user: $SSH_USER"

# --- Detect U5G-Max IP ---
msg "Querying MongoDB for U5G-Max IP..."
U5G_IP=$(mongo --quiet localhost:27117/ace \
    --eval "print(db.device.findOne({model:'UMBBE630'}).ip)" 2>/dev/null | tr -d '\r\n') || true

[ -z "$U5G_IP" ] || [ "$U5G_IP" = "null" ] && \
    die "U5G-Max (UMBBE630) not found in MongoDB — is the modem adopted?"

validate_ip "$U5G_IP"
ok "U5G-Max IP: $U5G_IP"

# --- Generate SSH key ---
msg "Generating SSH key..."
if [ -f "$SSH_KEY" ]; then
    warn "SSH key already exists at $SSH_KEY — skipping keygen"
else
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q -C "udm-bandfix@$(hostname)"
    ok "SSH key generated: $SSH_KEY"
fi
# Always enforce correct permissions
chmod 600 "$SSH_KEY"
chmod 644 "$SSH_KEY.pub"

# --- Scan host key into local known_hosts ---
msg "Scanning U5G-Max host key..."
ssh-keyscan -T 10 "$U5G_IP" > "$KNOWN_HOSTS" 2>/dev/null || \
    die "Could not reach $U5G_IP for host key scan — is the modem online?"
chmod 600 "$KNOWN_HOSTS"
ok "Host key stored: $KNOWN_HOSTS"

SSH_STRICT_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"

# --- Copy SSH public key to U5G-Max ---
msg "Installing SSH public key on U5G-Max (${SSH_USER}@${U5G_IP})..."

if ssh $SSH_STRICT_OPTS "${SSH_USER}@${U5G_IP}" "exit 0" 2>/dev/null; then
    warn "SSH key already installed on U5G-Max — skipping"
else
    # Write password to temp file — avoids exposing it in the process list via -p
    mkdir -p "$_TMP_DIR"
    chmod 700 "$_TMP_DIR"
    _PASS_FILE=$(mktemp "$_TMP_DIR/.udm-sshpass-XXXXXX")
    chmod 600 "$_PASS_FILE"
    printf '%s' "$SSH_PASS" > "$_PASS_FILE"

    sshpass -f "$_PASS_FILE" ssh-copy-id \
        -i "$SSH_KEY.pub" \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${U5G_IP}" 2>/dev/null || \
        die "ssh-copy-id failed — check password and connectivity to $U5G_IP"

    rm -f "$_PASS_FILE"; _PASS_FILE=""

    # Verify keyless SSH works
    ssh $SSH_STRICT_OPTS "${SSH_USER}@${U5G_IP}" "exit 0" || \
        die "Keyless SSH failed after key copy"

    ok "SSH key installed successfully"
fi

# --- Retrieve ICCID ---
msg "Reading ICCID from U5G-Max SIM..."
ICCID=$(printf '{"method":"get-sim-state"}' \
    | ssh $SSH_STRICT_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['iccid'])" 2>/dev/null) || true

[ -z "$ICCID" ] && die "Could not read ICCID — SIM initialized? Try again in 2 minutes."

# Validate ICCID: must be 18-20 digits
echo "$ICCID" | grep -qE '^[0-9]{18,20}$' || die "Unexpected ICCID format: '$ICCID'"
ok "ICCID: $ICCID"

# --- Write config ---
msg "Writing config file..."
cat > "$CONFIG" << EOF
# udm-bandfix config — written by install.sh $(date)
SSH_USER="$SSH_USER"
ICCID_CACHE="$ICCID"
EOF
chmod 600 "$CONFIG"
printf '%s\n' "$U5G_IP" > "$DATA_DIR/last_ip.txt"
ok "Config written: $CONFIG"

# --- Install band-fix.sh ---
msg "Installing band-fix.sh..."
SCRIPT_DEST="$DATA_DIR/band-fix.sh"
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$INSTALLER_DIR/src/band-fix.sh" ]; then
    cp "$INSTALLER_DIR/src/band-fix.sh" "$SCRIPT_DEST"
elif command -v curl >/dev/null 2>&1; then
    curl -sSL "$SCRIPT_SRC" -o "$SCRIPT_DEST" || die "Download of band-fix.sh failed"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$SCRIPT_DEST" "$SCRIPT_SRC" || die "Download of band-fix.sh failed"
else
    die "Cannot install band-fix.sh — no curl/wget and not running from local repo"
fi
chmod +x "$SCRIPT_DEST"
ok "band-fix.sh installed: $SCRIPT_DEST"

# --- Install cron job ---
msg "Installing cron job..."
cat > "$CRON_FILE" << 'EOF'
# udm-bandfix: Odido NL band enforcement for U5G-Max
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
# On boot: poll until modem online, then apply fix (also restores this cron if wiped)
@reboot root /data/udm-bandfix/on-boot.sh >> /data/udm-bandfix/band-fix.log 2>&1
# Hourly check to catch controller-pushed band resets
0 * * * * root /data/udm-bandfix/band-fix.sh >> /data/udm-bandfix/band-fix.log 2>&1
EOF
chmod 644 "$CRON_FILE"
ok "Cron job installed: $CRON_FILE (on-boot + hourly)"

# --- Install udm-bandfix CLI command ---
msg "Installing udm-bandfix command..."
CLI_DEST="/usr/local/sbin/udm-bandfix"
CLI_SRC="https://raw.githubusercontent.com/powerguardianOS/udm-bandfix/main/src/udm-bandfix.sh"
if [ -f "$INSTALLER_DIR/src/udm-bandfix.sh" ]; then
    cp "$INSTALLER_DIR/src/udm-bandfix.sh" "$CLI_DEST"
elif command -v curl >/dev/null 2>&1; then
    curl -sSL "$CLI_SRC" -o "$CLI_DEST" || warn "Could not download udm-bandfix.sh"
fi
[ -f "$CLI_DEST" ] && chmod +x "$CLI_DEST" && ok "CLI installed: type 'udm-bandfix' to manage"

# --- Install on-boot.sh to /data/ ---
msg "Installing on-boot.sh..."
ON_BOOT_DEST="$DATA_DIR/on-boot.sh"
ON_BOOT_SRC_URL="https://raw.githubusercontent.com/powerguardianOS/udm-bandfix/main/src/on-boot.sh"
if [ -f "$INSTALLER_DIR/src/on-boot.sh" ]; then
    cp "$INSTALLER_DIR/src/on-boot.sh" "$ON_BOOT_DEST"
elif command -v curl >/dev/null 2>&1; then
    curl -sSL "$ON_BOOT_SRC_URL" -o "$ON_BOOT_DEST" || warn "Could not download on-boot.sh"
fi
[ -f "$ON_BOOT_DEST" ] && chmod +x "$ON_BOOT_DEST" && ok "on-boot.sh installed: $ON_BOOT_DEST"

# --- Initial run ---
msg ""
msg "Running initial band fix..."
"$SCRIPT_DEST"

# --- Summary ---
printf '\n'
ok "udm-bandfix installed!"
printf '\n'
printf '  Config:      %s\n' "$CONFIG"
printf '  Log file:    %s\n' "$LOG_FILE"
printf '  Cron:        on-boot (polls until modem ready) + hourly\n'
printf '  U5G-Max:     %s\n' "$U5G_IP"
printf '  ICCID:       %s\n' "$ICCID"
printf '\n'
printf 'Monitor:       tail -f %s\n' "$LOG_FILE"
printf 'Manual run:    %s\n' "$SCRIPT_DEST"
printf 'Uninstall:     bash /data/udm-bandfix/uninstall.sh\n'
printf '\n'