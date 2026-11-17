#!/bin/bash
# tv-root-daemon — автоматично переакваєрить волатильний рут на Samsung TV Спальня
# після кожного ребуту/виходу-зі-standby.
#
# Логіка:
#   - Пінгуємо TV кожні 20 секунд
#   - Коли переходить offline→online: чекаємо 15с (щоб системи піднялися),
#     викликаємо `samsung-tv-root archive-root probe` через контейнер tvsign
#   - Все логуємо в LOG_FILE
#
# Запуск: tv-root-daemon.sh [--once | --foreground]
# Стоп:   kill -TERM <pid>

set -u
TV_IP="${TV_IP:-192.168.88.39}"
CONTAINER="${CONTAINER:-tvsign}"
TVROOT_DIR="${TVROOT_DIR:-/tmp/samsung-tv-root}"
SDB="${SDB:-/home/moonlight/tizen-studio/tools/sdb}"
PING_INTERVAL="${PING_INTERVAL:-20}"
WAKE_SETTLE="${WAKE_SETTLE:-15}"
LOG_FILE="${LOG_FILE:-/volume1/System/claude/tools/tv-root-daemon/tv-root-daemon.log}"
PID_FILE="${PID_FILE:-/volume1/System/claude/tools/tv-root-daemon/tv-root-daemon.pid}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

is_tv_up() {
  ping -c 1 -W 2 "$TV_IP" >/dev/null 2>&1
}

reacquire_root() {
  log "🔑 Реакваєрю рут на $TV_IP (archive-root probe)…"
  local out
  out=$(docker exec -u root "$CONTAINER" bash -c \
    "cd $TVROOT_DIR && .venv/bin/python -m samsung_tv_root --sdb $SDB archive-root probe $TV_IP" 2>&1)
  local rc=$?
  if [ $rc -eq 0 ]; then
    local uid
    uid=$(echo "$out" | grep -E '^uid:' | awk '{print $2}')
    log "✅ Рут отримано (uid=$uid, rc=0)"
    return 0
  else
    log "❌ Невдало (rc=$rc). Останні рядки:"
    echo "$out" | tail -5 | while read -r line; do log "   $line"; done
    return 1
  fi
}

cleanup() {
  log "🛑 Отримано сигнал — виходжу"
  rm -f "$PID_FILE"
  exit 0
}

trap cleanup TERM INT

case "${1:-}" in
  --once)
    reacquire_root
    exit $?
    ;;
  --status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "running (pid $(cat "$PID_FILE"))"
      echo "лог: $LOG_FILE"
      echo "останні 5 рядків:"
      tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
    else
      echo "not running"
    fi
    exit 0
    ;;
  --stop)
    if [ -f "$PID_FILE" ]; then
      pid=$(cat "$PID_FILE")
      kill -TERM "$pid" 2>/dev/null && echo "стопнуто pid $pid" || echo "pid $pid не знайдено"
      rm -f "$PID_FILE"
    else
      echo "не запущений"
    fi
    exit 0
    ;;
esac

# Якщо вже є інший екземпляр — виходимо
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "вже запущений (pid $(cat "$PID_FILE"))"
  exit 1
fi
echo $$ > "$PID_FILE"

log "🚀 Старт демона. TV=$TV_IP, інтервал ${PING_INTERVAL}s, settle ${WAKE_SETTLE}s"

# Стан
prev_up="unknown"
boot_reacquire_done=0

while true; do
  if is_tv_up; then
    curr_up="yes"
    if [ "$prev_up" = "no" ] || [ "$boot_reacquire_done" = "0" ]; then
      log "📺 TV онлайн (був: $prev_up). Чекаю ${WAKE_SETTLE}с на стабілізацію…"
      sleep "$WAKE_SETTLE"
      reacquire_root && boot_reacquire_done=1
    fi
  else
    curr_up="no"
    if [ "$prev_up" = "yes" ]; then
      log "📺 TV офлайн"
      boot_reacquire_done=0
    fi
  fi
  prev_up="$curr_up"
  sleep "$PING_INTERVAL"
done
