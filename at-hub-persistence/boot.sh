#!/bin/sh
# Installer для at-hub-persistence (адаптація під Tizen 9.0/rosel).
# Виконувати з root-контексту через stdin: cat boot.sh | MODULE_DIR=... bash
MODULE_DIR=${MODULE_DIR:-/opt/usr/share/selfroot/modules/at-hub-persistence}
EV=${EVIDENCE:-/opt/usr/share/selfroot/evidence}
H=/opt/etc/parseinfo.sh
B=/opt/usr/share/selfroot/backups/parseinfo.sh.stock
STOCK_SHA=c6369e7dec69408e176daa252d436acf6f8e265f560504d8bd831c8023c71d61

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$EV/install.log" 2>/dev/null; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

mkdir -p "$EV" /opt/usr/share/selfroot/backups 2>/dev/null
HOOK_SHA=$(sha "$MODULE_DIR/hook.awk")

cur=$(sha "$H")
if [ -z "$cur" ]; then
    log "FATAL: cannot read $H"; echo "cannot read $H"; exit 1
fi

if [ "$cur" = "$HOOK_SHA" ]; then
    log "hook already installed - no-op"; echo "already installed"; exit 0
fi

if [ "$cur" != "$STOCK_SHA" ]; then
    if [ "${FORCE:-0}" = "1" ]; then
        log "WARN: FORCE=1 over non-stock $H (sha $cur)"
    else
        log "REFUSED: $H is neither stock nor our hook (sha $cur)"
        echo "REFUSED: $H has unexpected sha $cur"
        echo "  stock expected: $STOCK_SHA"
        echo "  FORCE=1 to override after manual inspection"
        exit 1
    fi
fi

# first-time backup of stock bytes
if [ ! -f "$B" ]; then
    cp "$H" "$B" || { log "FATAL: backup failed"; echo "backup failed"; exit 1; }
    chmod 666 "$B"
    log "stock backed up to $B (sha $(sha "$B"))"
fi

# install hook
cat "$MODULE_DIR/hook.awk" > "$H" || { log "FATAL: hook write failed"; echo "install failed"; exit 1; }
chmod 777 "$H"
chown 0:0 "$H" 2>/dev/null
chsmack -a _ "$H" 2>/dev/null
sync

after=$(sha "$H")
if [ "$after" != "$HOOK_SHA" ]; then
    log "FATAL: post-install sha mismatch ($after != $HOOK_SHA); restoring stock"
    cat "$B" > "$H"
    echo "post-install verify failed, rolled back"; exit 1
fi

log "hook installed over $H (sha $after)"
echo "at-hub-persistence: hook installed."
echo "  rollback: cat $B > $H"
echo "  test: systemctl start AT-HUB.service   (then cat $EV/at-hub.log)"
exit 0
