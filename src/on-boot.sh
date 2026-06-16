#!/bin/bash
# on-boot.sh — udm-bandfix boot-time band enforcement
# Called via @reboot cron entry — not via on_boot.d (not available on UCG Fiber)
# Waits for U5G-Max to appear in MongoDB, then runs immediate band fix.

set -euo pipefail

SCRIPT_DEST="/data/udm-bandfix/band-fix.sh"
CRON_FILE="/etc/cron.d/udm-bandfix"
LOG_FILE="/data/udm-bandfix/band-fix.log"

log() {
    printf '[%s] on-boot: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

[ -f "$SCRIPT_DEST" ] || { log "band-fix.sh not found — skipping"; exit 0; }

# Restore cron job if wiped by a firmware update
if [ ! -f "$CRON_FILE" ]; then
    log "Cron job missing — restoring..."
    cat > "$CRON_FILE" << 'EOF'
# udm-bandfix: Odido NL band enforcement for U5G-Max
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
@reboot root sleep 120 && /data/udm-bandfix/on-boot.sh >> /data/udm-bandfix/band-fix.log 2>&1
0 * * * * root /data/udm-bandfix/band-fix.sh >> /data/udm-bandfix/band-fix.log 2>&1
EOF
    chmod 644 "$CRON_FILE"
    log "Cron job restored"
fi

# Poll MongoDB until U5G-Max appears (max 10 min — modem may boot slower than gateway)
log "Waiting for U5G-Max to appear in MongoDB..."
for i in $(seq 1 20); do
    IP=$(mongo --quiet localhost:27117/ace \
        --eval "print(db.device.findOne({model:'UMBBE630'}).ip)" 2>/dev/null \
        | tr -d '\r\n') || true
    if [ -n "$IP" ] && [ "$IP" != "null" ] && \
       [[ "$IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log "U5G-Max online at $IP — running band-fix..."
        "$SCRIPT_DEST" >> "$LOG_FILE" 2>&1 && \
            log "Boot fix applied successfully" || \
            log "band-fix exited with error (will retry via hourly cron)"
        exit 0
    fi
    log "Not ready yet (attempt $i/20) — waiting 30s..."
    sleep 30
done

log "U5G-Max did not appear within 10 minutes — band-fix will run via hourly cron"
