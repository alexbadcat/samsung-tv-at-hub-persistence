# Наш шлях / Our Journey

> 🇺🇦 Детальний технічний хронологічний запис як ми дійшли від "TV поза межею доступу" до "SSH root one command away".
> 🇬🇧 Detailed chronological technical journal: from "TV out of reach" to "SSH root one command away".

## Етап 0. Що у нас уже було

- Samsung TV QE65Q7F5AUXUA з Tizen 9.0/rosel
- Developer Mode увімкнений (ще з часів Moonlight)
- Контейнер `tvsign` з Samsung developer certs, Tizen Studio, SDB
- Знання про `chris-ritsen/samsung-tv-root` v0.0.13 як робочий початковий crypt для volatile root

## Етап 1. Volatile root через archive-root

Запустили `archive-root probe` — отримали UID 0, context=User, CapEff `0x3fffffffff`. Усе через контейнер `tvsign`, напряму з NAS. Створили `tv-root` CLI wrapper для щоденного використання.

**Проблема**: доступ зникає з ребутом TV. Треба щоразу запускати `archive-root probe` знову.

## Етап 2. NAS-side reacquire daemon

Написали bash-демон на NAS, який пінгує TV і при offline→online переході сам викликає `archive-root probe`. Персистентність на NAS:
- DSM EventScheduler `bootup` event
- Cron keepalive кожні 5 хв
- Watchdog registry моніторинг

Робочий daemon у `/volume1/System/claude/tools/tv-root-daemon/`. Але це все ще NAS-driven — TV залежить від зовнішньої машини.

## Етап 3. Шукаємо справжню persistence

Погуглили, знайшли **issue #17 chris-ritsen/samsung-tv-root** — там чиста recipe для boot-persistent root на Tizen 6.0 NIKEL. І форк `levkropp/samsung-tv-root-untethered` з готовим модулем для Q60B/6.5.

Ключові факти:
- Є vendor systemd-юніт `AT-HUB.service` без `User=` → запускається з UID 0 при кожному буті через `starter.target.wants/`
- Його `ExecStart=/opt/etc/parseinfo.sh` вказує на writable VDFS
- Отже заміна цього файлу = persistent boot hook

Перевіряємо на нашій 9.0/rosel:
- AT-HUB.service ✅ є
- parseinfo.sh ✅ писучий (mode 777)
- **sha256 нашого stock parseinfo.sh = c6369e7... — ЗБІГАЄТЬСЯ з levkropp's STOCK_SHA 1:1!**

Отже рецепт переноситься без змін. Chапі уся серія Samsung ділить один stock-файл.

## Етап 4. Встановлення AT-HUB hook

- Клонуємо levkropp fork, беремо `modules/at-hub-persistence/hook.awk` як є
- Пишемо власний мінімальний `runner.sh` (без bridge/telemetry/watchdog — тільки proof + SSH)
- Installer (`boot.sh`) — верифікує stock sha256, бекапить оригінал, замінює, верифікує hook sha256 після
- Заливаємо через HTTP server (sdb push блокує SMACK)

Запуск `systemctl restart AT-HUB.service` → читаємо `evidence/at-hub.log`:
```
SELFROOT-PROOF uid=0 gid=0 euid=0 via=at-hub
ctx=System::Privileged
capeff=CapEff: 0000003fffffffff
```

🎯 **Persistent root отриманий**. Але це ще не SSH.

## Етап 5. SSH крізь UEP

### 5.1 Перша спроба — static dropbear з Alpine

Залили cross-compiled static dropbear ARM з минулої сесії (Alpine-like build). Результат — `Operation not permitted`. UEP блокує native ELF.

### 5.2 UEP bypass — VDFS read-only bind

З issue #17: UEP акцептує exec через read-only mount view на VDFS. Пробуємо:
```sh
mkdir -p /opt/persist /opt/persist-ro
mount --bind /opt/persist /opt/persist-ro
mount -o remount,ro,bind /opt/persist-ro
```

І виконуємо з view — `/opt/persist-ro/dropbear -V` → **Dropbear v2024.85** ✅. Working!

Але nuance: UEP кешує по inode+writable-state. Якщо спершу запустити з writable path, потім ro-view fail. Отже FRESH inode через `cat > file.new && mv file.new file` → свіжий inode без історії кешу.

### 5.3 "Login attempt for nonexistent user"

SSH handshake проходить, host key акцептовано — АЛЕ:
```
Login attempt for nonexistent user
```

Причина: static dropbear + glibc getpwnam() внутрішньо робить dlopen на `libnss_files.so.2`. Tizen glibc 2.30, наш dropbear скомпільовано на Ubuntu 22.04 glibc 2.35 — ABI mismatch NSS modules.

Пробували:
- `LD_LIBRARY_PATH=/usr/lib` → spontaneous працює (parent), але forked children race-condition
- Patchelf RPATH — dropbear повністю static, нема `.dynamic`

### 5.4 FAKE_ROOT patch + recompile

Пишемо патч на `src/common-session.c`:
```c
pw = getpwnam(username);
if (!pw) {
    if (strcmp(username, "root") == 0 || strcmp(username, "owner") == 0) {
        ses.authstate.pw_uid = 0;
        ses.authstate.pw_gid = 0;
        ses.authstate.pw_name = m_strdup(username);
        ses.authstate.pw_dir = m_strdup("/home/owner");
        ses.authstate.pw_shell = m_strdup("/bin/bash");
        ses.authstate.pw_passwd = m_strdup("*");
        return;
    }
    return;
}
```

Cross-compile:
```bash
./configure --host=arm-linux-gnueabihf --disable-syslog --disable-zlib
make PROGRAMS="dropbear dropbearkey" LDFLAGS="-static"
```

Залили патчений dropbear на TV, старт через `systemd-run --scope`.

### 5.5 Нюанс /etc/passwd

Коли `getpwnam` все-таки знаходить юзера "owner" (uid=5001 Tizen-sandbox), dropbear перевіряє `strictmodes` і reject'ає. Фікс — додаємо класичний `root:x:0:0:root:/home/owner:/bin/bash` у /etc/passwd (`/etc/passwd` оверлейний, append працює на Tizen).

Також: `/home/owner/` owned by uid 5001 → chown 0:0 на все (home + .ssh + authorized_keys), chmod 755/700/600, SMACK label `_`.

### 5.6 ssh key auth works

```bash
$ ssh -i ~/.ssh/tv_spalnia_ed25519 -p 2222 root@192.168.88.39 'id'
uid=0(root) gid=0(root) context="User"
```

🎉 **SSH на TV працює** з усіх хостів у LAN.

## Результат

Пишемо runner.sh, який при буті:
1. Чекає boot-settle (systemd job queue drains)
2. Створює VDFS ro-bind
3. Staging fresh dropbear inode  
4. Genгрує host keys якщо нема
5. Deploy authorized_keys + chown 0:0
6. Додає `root:x:0:0:` у /etc/passwd
7. Запускає dropbear через systemd-run --scope

Після будь-якого ребуту TV — SSH :2222 підіймається сам, без зовнішньої команди.

## Summary table / Зведена таблиця

| Шар / Layer | Де / Where | Що робить / What it does |
|---|---|---|
| AT-HUB hook | TV: `/opt/etc/parseinfo.sh` (gawk) | UID 0 System::Privileged на кожному буті |
| runner.sh | TV: `/opt/usr/share/selfroot/modules/at-hub-persistence/` | SSH + UEP bypass per-boot |
| dropbear (FAKE_ROOT) | TV: `/opt/persist/dropbear` + ro-view | SSH server :2222 |
| tv-root-daemon | NAS: `/volume1/System/claude/tools/tv-root-daemon/` | Volatile backup acquire |
| tv-root CLI | NAS: `/volume1/System/claude/bin/tv-root` | Human interface |

## Credits

- @chris-ritsen — [samsung-tv-root](https://github.com/chris-ritsen/samsung-tv-root), archive-root chain, issue #17 UEP discovery
- @levkropp — [samsung-tv-root-untethered](https://github.com/levkropp/samsung-tv-root-untethered), AT-HUB vendor hook recipe
- Dropbear — [matt.ucc.asn.au](https://matt.ucc.asn.au/dropbear/dropbear.html)
