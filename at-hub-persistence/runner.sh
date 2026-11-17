#!/bin/sh
# Boot runner: proof + dropbear SSH сервер з UEP bypass через VDFS ro-bind.
EV=/opt/usr/share/selfroot/evidence
MOD=/opt/usr/share/selfroot/modules/at-hub-persistence
BOOT_TS=$(date '+%Y-%m-%d %H:%M:%S')
SSH_PORT=2222

mkdir -p "$EV" 2>/dev/null
chmod 0777 "$EV" 2>/dev/null
chsmack -a _ "$EV" 2>/dev/null

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$EV/at-hub.log"
}

{
  echo "SELFROOT-PROOF uid=$(id -u) gid=$(id -g) euid=$(id -u) via=at-hub"
  echo "$BOOT_TS boot runner start (uptime $(cut -d. -f1 /proc/uptime 2>/dev/null)s)"
  echo "ctx=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\n')"
  echo "capeff=$(grep CapEff /proc/self/status 2>/dev/null)"
} > "$EV/selfroot-proof.txt"
chmod 666 "$EV/selfroot-proof.txt" 2>/dev/null
chsmack -a _ "$EV/selfroot-proof.txt" 2>/dev/null
log "runner start uid=$(id -u) ctx=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\n')"

chmod 666 "$EV/at-hub.log" 2>/dev/null
chsmack -a _ "$EV/at-hub.log" 2>/dev/null

# Boot settle — AT-HUB fires early, systemd job queue може бути зайнятий
log "boot-settle wait up to 60s for job queue drain"
i=0
while [ "$i" -lt 12 ] && [ "$(systemctl list-jobs --no-pager 2>/dev/null | wc -l)" -gt 1 ]; do
  sleep 5; i=$((i + 1))
done
log "boot-settle done after ${i}0s"

# ── UEP-safe setup ──
mkdir -p /opt/persist /opt/persist-ro 2>/dev/null
if ! mount | grep -q "/opt/persist-ro.*vdfs"; then
  mount --bind /opt/persist /opt/persist-ro 2>>"$EV/at-hub.log"
  mount -o remount,ro,bind /opt/persist-ro 2>>"$EV/at-hub.log"
  log "VDFS ro-bind mounted"
fi

# Свіжа копія dropbear/dropbearkey (новий inode кожен раз)
for b in dropbear dropbearkey; do
  if [ -f "$MOD/$b" ]; then
    cat "$MOD/$b" > "/opt/persist/$b.new"
    chmod 755 "/opt/persist/$b.new"
    chsmack -a _ "/opt/persist/$b.new" 2>/dev/null
    sync
    mv "/opt/persist/$b.new" "/opt/persist/$b"
  fi
done
log "dropbear binaries staged"

# Host-ключі
mkdir -p /opt/persist/keys
chmod 700 /opt/persist/keys
if [ ! -f /opt/persist/keys/dropbear_ed25519_host_key ]; then
  /opt/persist-ro/dropbearkey -t ed25519 -f /opt/persist/keys/dropbear_ed25519_host_key >>"$EV/at-hub.log" 2>&1
fi
if [ ! -f /opt/persist/keys/dropbear_rsa_host_key ]; then
  /opt/persist-ro/dropbearkey -t rsa -s 2048 -f /opt/persist/keys/dropbear_rsa_host_key >>"$EV/at-hub.log" 2>&1
fi

# authorized_keys з модуля → в /home/owner/.ssh/
mkdir -p /home/owner/.ssh 2>/dev/null
chmod 700 /home/owner/.ssh
if [ -f "$MOD/authorized_keys" ]; then
  cp "$MOD/authorized_keys" /home/owner/.ssh/authorized_keys
  chmod 600 /home/owner/.ssh/authorized_keys
  chown owner:users /home/owner/.ssh/authorized_keys 2>/dev/null
  log "authorized_keys deployed"
fi


# /etc/passwd: додаємо класичний root якщо його нема
if ! grep -q "^root:" /etc/passwd; then
  echo "root:x:0:0:root:/home/owner:/bin/bash" >> /etc/passwd 2>/dev/null
  log "added root user to /etc/passwd"
fi
# chown власник на /home/owner і authorized_keys (strictmodes)
chown 0:0 /home/owner /home/owner/.ssh /home/owner/.ssh/authorized_keys 2>/dev/null
chmod 755 /home/owner
chmod 700 /home/owner/.ssh
chmod 600 /home/owner/.ssh/authorized_keys
chsmack -a _ /home/owner/.ssh/authorized_keys 2>/dev/null
log "owner home + authorized_keys permissions set"

# Запуск dropbear (якщо ще не слухає)
if ! ss -lnt 2>/dev/null | grep -q ":$SSH_PORT " && ! pgrep -f "dropbear -F -p $SSH_PORT" >/dev/null 2>&1; then
  # systemd-run --scope виносить dropbear у окремий transient cgroup,
  # щоб AT-HUB.service не вбивав його при завершенні parseinfo.sh/runner.sh.
  systemd-run --scope --unit=tv-sshd --quiet \
    /opt/persist-ro/dropbear -F -p "$SSH_PORT" \
    -r /opt/persist/keys/dropbear_ed25519_host_key \
    -r /opt/persist/keys/dropbear_rsa_host_key \
    >>"$EV/dropbear.log" 2>&1 &
  disown
  sleep 2
  if pgrep -f "dropbear -F -p $SSH_PORT" >/dev/null 2>&1; then
    log "dropbear listening on $SSH_PORT (systemd-run scope)"
  else
    # Fallback: setsid
    log "systemd-run scope not listening, fallback to setsid"
    setsid nohup /opt/persist-ro/dropbear -F -p "$SSH_PORT" \
      -r /opt/persist/keys/dropbear_ed25519_host_key \
      -r /opt/persist/keys/dropbear_rsa_host_key \
      >>"$EV/dropbear.log" 2>&1 < /dev/null &
    disown
    sleep 2
    if pgrep -f "dropbear -F -p $SSH_PORT" >/dev/null 2>&1; then
      log "dropbear listening on $SSH_PORT (fallback setsid)"
    else
      log "ERROR: dropbear failed on $SSH_PORT"
    fi
  fi
else
  log "dropbear already running on $SSH_PORT"
fi

sync
exit 0
