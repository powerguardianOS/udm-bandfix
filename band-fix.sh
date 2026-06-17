#!/bin/bash
# udm-bandfix: Enforce Odido NL band restrictions on U5G-Max from Cloud Gateway
# Source: Odido 5G Internet hardware specificaties en voorwaarden
# Required active bands: LTE B1/B3/B7/B38, NR n1/n3/n7/n38/n78
# Forbidden bands (must be disabled): B8, B20, B28, n8, n20, n28

set -euo pipefail
exec </dev/null

DATA_DIR="/data/udm-bandfix"
TMP_DIR="$DATA_DIR/tmp"
LOG_FILE="$DATA_DIR/band-fix.log"
CONFIG="$DATA_DIR/config"
SSH_KEY="$DATA_DIR/id_ed25519"
KNOWN_HOSTS="$DATA_DIR/known_hosts"
LAST_IP_FILE="$DATA_DIR/last_ip.txt"

# Exact Odido-specified band lists per official hardware spec (3GPP Release 16)
LTE_REQUIRED="1,3,7,38"
NR5G_SA_REQUIRED="1,3,7,38,78"
NR5G_NSA_REQUIRED="1,3,7,38,78"

# Max log size before rotation (bytes)
LOG_MAX_BYTES=524288  # 512 KB

# Strip non-printable characters
strip_nonprintable() {
    printf '%s' "$1" | tr -cd '[:print:]'
}

log() {
    local msg line
    msg=$(strip_nonprintable "$*")
    line="$(printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg")"
    printf '%s\n' "$line" >> "$LOG_FILE"
    [ -t 1 ] && printf '%s\n' "$line"
}

die() {
    log "ERROR: $*"
    exit 1
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        log "Log rotated (kept last 500 lines)"
    fi
}

validate_ip() {
    local ip="$1"
    ip=$(strip_nonprintable "$ip")
    if ! printf '%s' "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        die "Invalid IP address from MongoDB: '$ip' — possible injection attempt"
    fi
}

validate_ssh_user() {
    local user="$1"
    if ! printf '%s' "$user" | grep -qE '^[a-zA-Z0-9_-]{1,32}$'; then
        die "Invalid SSH_USER in config: '$user' — must be 1-32 alphanumeric/underscore/dash chars"
    fi
}

# --- Log rotation ---
rotate_log

# --- Create temp directory ---
mkdir -p "$TMP_DIR"
chmod 700 "$TMP_DIR"

# --- Singleton guard (atomic via mkdir) ---
LOCK_DIR="$DATA_DIR/.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another instance is running — exiting"
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null; rm -f "$TMP_DIR"/udm-bandfix-*' EXIT

# --- Load config ---
[ -f "$CONFIG" ] || die "Config not found: $CONFIG (run install.sh first)"
# shellcheck source=/dev/null
source "$CONFIG"
: "${SSH_USER:?CONFIG missing SSH_USER}"
validate_ssh_user "$SSH_USER"

# --- Get current U5G-Max IP (changes on reboot) ---
log "Querying MongoDB for U5G-Max IP..."
_mongo_out="$TMP_DIR/mongo_ip.txt"
timeout 30 mongo --quiet localhost:27117/ace \
    --eval "print(db.device.findOne({model:'UMBBE630'}).ip)" \
    < /dev/null > "$_mongo_out" 2>/dev/null || true
U5G_IP=$(tr -d '\r\n' < "$_mongo_out")
rm -f "$_mongo_out"
log "DEBUG: mongo done, result='$U5G_IP'"

[ -z "$U5G_IP" ] && die "MongoDB query timed out or failed — U5G-Max IP unavailable"
[ "$U5G_IP" = "null" ] && die "U5G-Max (UMBBE630) not found in MongoDB — is the modem adopted?"

# Validate IP before using it in any shell command
validate_ip "$U5G_IP"
log "U5G-Max IP: $U5G_IP"

# --- Update known_hosts if IP changed ---
LAST_IP=""
[ -f "$LAST_IP_FILE" ] && LAST_IP=$(cat "$LAST_IP_FILE")

if [ "$U5G_IP" != "$LAST_IP" ]; then
    log "IP changed ($LAST_IP → $U5G_IP) — updating known_hosts..."
    # Atomic known_hosts update
    if [ -f "$KNOWN_HOSTS" ]; then
        ssh-keygen -R "$LAST_IP" -f "$KNOWN_HOSTS" 2>/dev/null || true
    fi
    ssh-keyscan -T 10 "$U5G_IP" > "$TMP_DIR/known_hosts.tmp" 2>/dev/null || \
        die "Could not scan SSH host key for $U5G_IP"
    mv "$TMP_DIR/known_hosts.tmp" "$KNOWN_HOSTS"
    printf '%s\n' "$U5G_IP" > "$LAST_IP_FILE"
fi

SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"

# --- SSH connectivity check ---
if ! ssh $SSH_OPTS "${SSH_USER}@${U5G_IP}" "exit 0" 2>/dev/null; then
    log "WARNING: SSH to $U5G_IP failed — device offline or key not installed (re-run install.sh)"
    exit 0  # non-fatal, cron will retry
fi

# --- Fetch ICCID live from modem (not from static config — survives SIM swaps) ---
log "Reading ICCID from modem..."
ICCID=$(printf '{"method":"get-sim-state"}' \
    | ssh $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['iccid'])" 2>/dev/null) || true

if [ -z "$ICCID" ]; then
    # Fallback to cached ICCID (SIM may still be initializing)
    [ -n "${ICCID_CACHE:-}" ] && ICCID="$ICCID_CACHE" || \
        die "Could not read ICCID from modem and no cache available"
    log "WARNING: Using cached ICCID (modem may still be initializing)"
fi

# Validate ICCID: must be 18-20 digits (strip non-printable first)
ICCID=$(strip_nonprintable "$ICCID")
if ! printf '%s' "$ICCID" | grep -qE '^[0-9]{18,20}$'; then
    die "Invalid ICCID: '$ICCID'"
fi
log "ICCID: $ICCID"

# Cache ICCID for next run in case modem is slow to initialize
if [ "${ICCID_CACHE:-}" != "$ICCID" ]; then
    # Update the config file with the new cached ICCID
    if grep -q "^ICCID_CACHE=" "$CONFIG" 2>/dev/null; then
        sed -i "s/^ICCID_CACHE=.*/ICCID_CACHE=\"$ICCID\"/" "$CONFIG"
    else
        printf 'ICCID_CACHE="%s"\n' "$ICCID" >> "$CONFIG"
    fi
fi

# --- Fetch current band configuration ---
log "Fetching current band config..."
CURRENT=$(printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}' "$ICCID" \
    | ssh $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" 2>/dev/null) || \
    die "get-radio-pref failed"
log "Current: $CURRENT"

# --- Fetch current RAT mode ---
RAT_STATUS=$(printf '{"method":"get-radio-status"}' | ssh $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" 2>/dev/null) || true
RAT_MODE=$(printf '%s' "$RAT_STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('rat-mode-active',''))" 2>/dev/null) || true
RAT_MODE=$(strip_nonprintable "$RAT_MODE")

if [ "$RAT_MODE" = "WCDMA" ]; then
    log "WARNING: WCDMA detected — modem stuck on 3G, forcing reregistration to 4G/5G"
    _tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N)-rat.json"
    printf '%s\n' '{"method":"set-radio-pref","params":{"iccid":"'"$ICCID"'","mode":"5gnr,lte"}}' > "$_tmpfile"
    RESULT=$(ssh $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile") || true
    rm -f "$_tmpfile"
    if echo "$RESULT" | grep -q '"result":{}'; then
        log "SUCCESS: RAT mode reconfiguration triggered"
    else
        log "WARNING: RAT mode reconfiguration attempted but unexpected response: $RESULT"
    fi
    log "Waiting 60s for modem to reregister..."
    sleep 60
    # Re-fetch RAT mode
    RAT_STATUS=$(printf '{"method":"get-radio-status"}' | ssh $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" 2>/dev/null) || true
    RAT_MODE=$(printf '%s' "$RAT_STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('rat-mode-active',''))" 2>/dev/null) || true
    RAT_MODE=$(strip_nonprintable "$RAT_MODE")
    if [ "$RAT_MODE" = "WCDMA" ]; then
        log "WCDMA persists after reregistration — modem may need manual intervention, skipping band fix this run"
        exit 0
    fi
    # Re-fetch band config
    CURRENT=$(printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}' "$ICCID" \
        | ssh $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" 2>/dev/null) || \
        die "get-radio-pref failed"
    log "Current: $CURRENT"
fi

# --- Check compliance: compare against exact Odido spec ---
check_compliance() {
    local json="$1"
    python3 - "$json" "$LTE_REQUIRED" "$NR5G_SA_REQUIRED" "$NR5G_NSA_REQUIRED" << 'PYEOF'
import json, sys

def parse_bands(s):
    return {int(b.strip()) for b in s.split(",") if b.strip().isdigit()}

try:
    current = json.loads(sys.argv[1])
    result = current.get("result", {})
    required = {
        "lte_band":      parse_bands(sys.argv[2]),
        "nr5g_sa_band":  parse_bands(sys.argv[3]),
        "nr5g_nsa_band": parse_bands(sys.argv[4]),
    }
    mismatches = []
    for key, req_bands in required.items():
        actual_str = result.get(key, "")
        actual_bands = parse_bands(actual_str) if actual_str else set()
        if actual_bands != req_bands:
            extra   = sorted(actual_bands - req_bands)
            missing = sorted(req_bands - actual_bands)
            parts = []
            if extra:   parts.append(f"extra={extra}")
            if missing: parts.append(f"missing={missing}")
            mismatches.append(f"  {key}: {', '.join(parts)}")
    if mismatches:
        for m in mismatches:
            print(m)
    sys.exit(0)
except Exception as e:
    # Log full JSON for debugging firmware format changes
    print(f"Parse error: {e} — raw input: {sys.argv[1][:200]}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

MISMATCHES=$(check_compliance "$CURRENT")
if [ -z "$MISMATCHES" ]; then
    log "OK: Band configuration matches Odido spec — nothing to do"
    exit 0
fi

log "Non-compliant configuration detected:"
while IFS= read -r line; do
    log "$line"
done <<< "$MISMATCHES"

# --- Apply band fix ---
log "Applying Odido-spec band configuration..."

PAYLOAD=$(printf \
    '{"method":"set-radio-pref","params":{"iccid":"%s","lte_band":"%s","nr5g_sa_band":"%s","nr5g_nsa_band":"%s"}}' \
    "$ICCID" "$LTE_REQUIRED" "$NR5G_SA_REQUIRED" "$NR5G_NSA_REQUIRED")

# Write to temp file in /data/udm-bandfix/tmp/ and feed as stdin through SSH
_tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N).json"
printf '%s\n' "$PAYLOAD" > "$_tmpfile"
RESULT=$(ssh $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile") || \
    die "set-radio-pref command failed"
rm -f "$_tmpfile"

if echo "$RESULT" | grep -q '"result":{}'; then
    log "SUCCESS: Band configuration applied"
else
    die "Unexpected response from set-radio-pref: $RESULT"
fi

# --- Verify ---
log "Verifying..."
VERIFY=$(printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}' "$ICCID" \
    | ssh $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" 2>/dev/null)
REMAINING=$(check_compliance "$VERIFY")
if [ -n "$REMAINING" ]; then
    die "Fix applied but config still non-compliant:$REMAINING"
fi

log "VERIFIED: Odido-compliant band configuration confirmed"
log "Done."