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

# --- Helper: run mongo with guaranteed termination via background+SIGKILL ---
# `timeout` and SSH ConnectTimeout do not work in UCG Fiber cron: the cron
# environment does not propagate signals to child processes reliably.
# Background process + explicit kill -9 works in all environments.
_query_mongo_ip() {
    local _out="$TMP_DIR/mongo_ip.txt"
    local _rc=0
    : > "$_out"
    mongo --quiet --connectTimeoutMS 10000 --socketTimeoutMS 10000 \
        localhost:27117/ace \
        --eval "print(db.device.findOne({model:'UMBBE630'}).ip)" \
        < /dev/null > "$_out" 2>/dev/null &
    local _pid=$!
    ( sleep 30 && kill -9 "$_pid" 2>/dev/null ) &
    local _kpid=$!
    { wait "$_pid" 2>/dev/null; } || _rc=$?
    kill "$_kpid" 2>/dev/null; wait "$_kpid" 2>/dev/null || true
    tr -d '\r\n' < "$_out"
    rm -f "$_out"
    return $_rc
}

# --- Helper: run SSH with guaranteed termination via background+SIGKILL (20s max) ---
# Usage: _ssh_bg <outfile> [ssh args...] (stdin from caller via redirect)
# Output captured to outfile; returns ssh exit code.
#
# IMPORTANT: bash redirects background process stdin to /dev/null when job
# control is disabled (cron, non-interactive). We save the caller's stdin to a
# tempfile BEFORE backgrounding, then pass it explicitly so ssh/uiwwand-ctl
# gets the JSON payload.
_ssh_bg() {
    local _out="$1"; shift
    local _rc=0 _in="$TMP_DIR/ssh_bg_stdin_$$"
    cat > "$_in"        # drain caller's stdin NOW (foreground — inherits caller's redirect)
    : > "$_out"
    ssh "$@" < "$_in" > "$_out" 2>/dev/null &
    local _pid=$!
    ( sleep 20 && kill -9 "$_pid" 2>/dev/null ) &
    local _kpid=$!
    { wait "$_pid" 2>/dev/null; } || _rc=$?
    kill "$_kpid" 2>/dev/null; wait "$_kpid" 2>/dev/null || true
    rm -f "$_in"
    return $_rc
}

# --- Helper: update known_hosts when IP changes ---
# ssh-keyscan uses SIGALRM internally for its -T timeout, which does not
# fire reliably in the UCG Fiber cron container namespace — wrap it in the
# same background+SIGKILL pattern used for mongo and ssh.
_update_known_hosts() {
    local _old="$1" _new="$2" _rc=0
    log "IP changed ($_old → $_new) — updating known_hosts..."
    if [ -f "$KNOWN_HOSTS" ] && [ -n "$_old" ]; then
        ssh-keygen -R "$_old" -f "$KNOWN_HOSTS" 2>/dev/null || true
    fi
    : > "$TMP_DIR/known_hosts.tmp"
    ssh-keyscan -T 10 "$_new" > "$TMP_DIR/known_hosts.tmp" 2>/dev/null &
    local _kspid=$!
    ( sleep 15 && kill -9 "$_kspid" 2>/dev/null ) &
    local _kkpid=$!
    { wait "$_kspid" 2>/dev/null; } || _rc=$?
    kill "$_kkpid" 2>/dev/null; wait "$_kkpid" 2>/dev/null || true
    if [ $_rc -ne 0 ] || [ ! -s "$TMP_DIR/known_hosts.tmp" ]; then
        rm -f "$TMP_DIR/known_hosts.tmp"
        die "Could not scan SSH host key for $_new (timeout or no keys returned)"
    fi
    mv "$TMP_DIR/known_hosts.tmp" "$KNOWN_HOSTS"
    printf '%s\n' "$_new" > "$LAST_IP_FILE"
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
trap 'rmdir "$LOCK_DIR" 2>/dev/null; rm -f "$TMP_DIR"/udm-bandfix-* "$TMP_DIR"/mongo_ip.txt "$TMP_DIR"/ssh_*.txt "$TMP_DIR"/ssh_bg_stdin_* "$TMP_DIR"/known_hosts.tmp' EXIT

# --- Load config ---
[ -f "$CONFIG" ] || die "Config not found: $CONFIG (run install.sh first)"
# shellcheck source=/dev/null
source "$CONFIG"
: "${SSH_USER:?CONFIG missing SSH_USER}"
validate_ssh_user "$SSH_USER"

# --- Get current U5G-Max IP (cache-first: skip mongo on normal cron runs) ---
LAST_IP=""
[ -f "$LAST_IP_FILE" ] && LAST_IP=$(tr -d '\r\n' < "$LAST_IP_FILE")

U5G_IP=""
if printf '%s' "$LAST_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' 2>/dev/null; then
    U5G_IP="$LAST_IP"
    log "U5G-Max IP (cached): $U5G_IP"
else
    log "No cached IP — querying MongoDB..."
    U5G_IP=$(_query_mongo_ip)
    log "MongoDB result: '$U5G_IP'"
    [ -z "$U5G_IP" ] && die "MongoDB unavailable and no cached IP"
    [ "$U5G_IP" = "null" ] && die "U5G-Max (UMBBE630) not found in MongoDB — is the modem adopted?"
    validate_ip "$U5G_IP"
    _update_known_hosts "" "$U5G_IP"
fi

SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"

# --- SSH connectivity check (if cached IP fails, refresh via MongoDB) ---
log "Checking SSH connectivity..."
_chk="$TMP_DIR/ssh_chk.txt"
if ! _ssh_bg "$_chk" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "exit 0"; then
    log "SSH failed at $U5G_IP — querying MongoDB for updated IP..."
    _fresh=$(_query_mongo_ip)
    if printf '%s' "$_fresh" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        if [ "$_fresh" != "$U5G_IP" ]; then
            _update_known_hosts "$U5G_IP" "$_fresh"
            U5G_IP="$_fresh"
        fi
        if ! _ssh_bg "$_chk" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "exit 0"; then
            log "WARNING: SSH to U5G-Max failed — device offline or key not installed (re-run install.sh)"
            exit 0
        fi
    else
        log "WARNING: SSH to U5G-Max failed — device offline or key not installed (re-run install.sh)"
        exit 0
    fi
fi

# --- Fetch ICCID live from modem (not from static config — survives SIM swaps) ---
log "Reading ICCID from modem..."
_tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N)-sim.json"
_ssh_out="$TMP_DIR/ssh_sim.txt"
printf '%s\n' '{"method":"get-sim-state"}' > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || true
_sim_out=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"
ICCID=$(printf '%s' "$_sim_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result']['iccid'])" 2>/dev/null) || true

if [ -z "$ICCID" ]; then
    [ -n "${ICCID_CACHE:-}" ] && ICCID="$ICCID_CACHE" || \
        die "Could not read ICCID from modem and no cache available"
    log "WARNING: Using cached ICCID (modem may still be initializing)"
fi

ICCID=$(strip_nonprintable "$ICCID")
if ! printf '%s' "$ICCID" | grep -qE '^[0-9]{18,20}$'; then
    die "Invalid ICCID: '$ICCID'"
fi
log "ICCID: $ICCID"

if [ "${ICCID_CACHE:-}" != "$ICCID" ]; then
    if grep -q "^ICCID_CACHE=" "$CONFIG" 2>/dev/null; then
        sed -i "s/^ICCID_CACHE=.*/ICCID_CACHE=\"$ICCID\"/" "$CONFIG"
    else
        printf 'ICCID_CACHE="%s"\n' "$ICCID" >> "$CONFIG"
    fi
fi

# --- Fetch current band configuration ---
log "Fetching current band config..."
_tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N)-get.json"
_ssh_out="$TMP_DIR/ssh_get.txt"
printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}\n' "$ICCID" > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || \
    { rm -f "$_tmpfile" "$_ssh_out"; die "get-radio-pref failed"; }
CURRENT=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"

if [ -z "$CURRENT" ]; then
    log "WARNING: uiwwand-ctl returned empty response — modem still initializing, cron will retry"
    exit 0
fi
log "Current: $CURRENT"

# --- Fetch current RAT mode ---
_tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N)-rat-st.json"
_ssh_out="$TMP_DIR/ssh_rat_st.txt"
printf '%s\n' '{"method":"get-radio-status"}' > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || true
RAT_STATUS=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"
RAT_MODE=$(printf '%s' "$RAT_STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('rat-mode-active',''))" 2>/dev/null) || true
RAT_MODE=$(strip_nonprintable "$RAT_MODE")

if [ "$RAT_MODE" = "WCDMA" ]; then
    log "WARNING: WCDMA detected — modem stuck on 3G, forcing reregistration to 4G/5G"
    _tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N)-rat.json"
    _ssh_out="$TMP_DIR/ssh_rat_set.txt"
    printf '%s\n' '{"method":"set-radio-pref","params":{"iccid":"'"$ICCID"'","mode":"5gnr,lte"}}' > "$_tmpfile"
    _ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || true
    RESULT=$(cat "$_ssh_out")
    rm -f "$_tmpfile" "$_ssh_out"
    if echo "$RESULT" | grep -q '"result":{}'; then
        log "SUCCESS: RAT mode reconfiguration triggered"
    else
        log "WARNING: RAT mode reconfiguration attempted but unexpected response: $RESULT"
    fi
    log "Waiting 60s for modem to reregister..."
    sleep 60
    _tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N)-rat-st2.json"
    _ssh_out="$TMP_DIR/ssh_rat_st2.txt"
    printf '%s\n' '{"method":"get-radio-status"}' > "$_tmpfile"
    _ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || true
    RAT_STATUS=$(cat "$_ssh_out")
    rm -f "$_tmpfile" "$_ssh_out"
    RAT_MODE=$(printf '%s' "$RAT_STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',{}).get('rat-mode-active',''))" 2>/dev/null) || true
    RAT_MODE=$(strip_nonprintable "$RAT_MODE")
    if [ "$RAT_MODE" = "WCDMA" ]; then
        log "WCDMA persists after reregistration — modem may need manual intervention, skipping band fix this run"
        exit 0
    fi
    _tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N)-get2.json"
    _ssh_out="$TMP_DIR/ssh_get2.txt"
    printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}\n' "$ICCID" > "$_tmpfile"
    _ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || \
        { rm -f "$_tmpfile" "$_ssh_out"; die "get-radio-pref failed"; }
    CURRENT=$(cat "$_ssh_out")
    rm -f "$_tmpfile" "$_ssh_out"
    if [ -z "$CURRENT" ]; then
        log "WARNING: uiwwand-ctl returned empty after WCDMA recovery — modem still initializing, cron will retry"
        exit 0
    fi
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

_tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N).json"
_ssh_out="$TMP_DIR/ssh_set.txt"
printf '%s\n' "$PAYLOAD" > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || \
    { rm -f "$_tmpfile" "$_ssh_out"; die "set-radio-pref command failed"; }
RESULT=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"

if echo "$RESULT" | grep -q '"result":{}'; then
    log "SUCCESS: Band configuration applied"
else
    die "Unexpected response from set-radio-pref: $RESULT"
fi

# --- Verify ---
log "Verifying..."
_tmpfile="$TMP_DIR/udm-bandfix-$(date +%s%N)-verify.json"
_ssh_out="$TMP_DIR/ssh_verify.txt"
printf '{"method":"get-radio-pref","params":{"iccid":"%s"}}\n' "$ICCID" > "$_tmpfile"
_ssh_bg "$_ssh_out" $SSH_OPTS "${SSH_USER}@${U5G_IP}" "uiwwand-ctl" < "$_tmpfile" || \
    die "verify get-radio-pref failed"
VERIFY=$(cat "$_ssh_out")
rm -f "$_tmpfile" "$_ssh_out"
REMAINING=$(check_compliance "$VERIFY")
if [ -n "$REMAINING" ]; then
    die "Fix applied but config still non-compliant:$REMAINING"
fi

log "VERIFIED: Odido-compliant band configuration confirmed"
log "Done."
