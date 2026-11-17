#!/bin/sh
# Крон-перевірка: якщо демон не живий — старт знову.
DAEMON=/volume1/System/claude/tools/tv-root-daemon/tv-root-daemon.sh
if ! pgrep -f "tv-root-daemon.sh" | grep -v "tv-root-daemon-keepalive" >/dev/null 2>&1; then
  nohup "$DAEMON" >/dev/null 2>&1 &
fi
