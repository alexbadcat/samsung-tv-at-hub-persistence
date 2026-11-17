# Samsung Tizen TV — Persistent Root + SSH (AT-HUB Hook)

> 🇺🇦 **Українська версія — нижче на цій сторінці**
> 🇬🇧 **English version — see [README.en.md](README.en.md)** (mirror)

---

## 🇺🇦 Про що це

Повний інженерний путівник: як отримати **постійний root-доступ + SSH-сервер** на Samsung TV з Tizen OS, щоб переживало ребут без жодного host-side injection'у. Перевірено наживо на `QE65Q7F5AUXUA` (Tizen 9.0, rosel, armv7l, firmware `T-RSLFDEUC-0090`).

Концептуально будується на двох чужих роботах, за що велика вдячність авторам:
- [chris-ritsen/samsung-tv-root](https://github.com/chris-ritsen/samsung-tv-root) — початковий **volatile** root через SDB Developer Mode → .NET capability chain (`archive-root`)
- [levkropp/samsung-tv-root-untethered](https://github.com/levkropp/samsung-tv-root-untethered) — концепція **AT-HUB vendor service hook** для boot-persistent root (на Q60B/Tizen 6.5)

Наш внесок:
- **Адаптація AT-HUB hook під Tizen 9.0/rosel** (той самий stock parseinfo.sh, той самий sha256 `c6369e7...` — рецепт переноситься 1:1)
- **FAKE_ROOT patch для dropbear** — щоб static-linked SSH сервер працював на Tizen, де static glibc NSS не знаходить `root` у `/etc/passwd`
- **NAS-side backup daemon** — хост-утиліта на Synology/Xpenology, що моніторить TV і реакваєрить volatile root як страховка, якщо щось у AT-HUB зламалось
- **Детальний запис нашого шляху** від нуля до працюючого SSH

## 🇺🇦 Що ми отримуємо

Після повного встановлення:
```bash
# З будь-якого хоста в LAN (NAS, ноут, телефон):
ssh -i ~/.ssh/tv_spalnia_ed25519 -p 2222 root@192.168.88.39
# → одразу в root shell на TV, UID 0, повний CapEff 0x3fffffffff
```

І воно працює **після будь-якого ребуту TV** — без жодної команди з NAS, без SDB, без Developer Mode (Dev Mode потрібен лише для початкового встановлення).

## 🇺🇦 Архітектура

```
┌─────────────────────────────────────────────────────────────┐
│ ПРИ БУТІ TV:                                                 │
│   systemd starter.target                                     │
│    └─ AT-HUB.service (vendor unit, no User= → root)         │
│        └─ /opt/etc/parseinfo.sh  ← НАШ gawk-хук              │
│            ├─ vendor target_version write (збережено 1:1)   │
│            └─ system("cat runner.sh | bash")                 │
│                ├─ VDFS read-only bind /opt/persist           │
│                ├─ dropbear host-keys gen (якщо нема)         │
│                ├─ authorized_keys deploy                     │
│                └─ systemd-run --scope dropbear :2222         │
└─────────────────────────────────────────────────────────────┘
       ↓
┌─────────────────────────────────────────────────────────────┐
│ У ПРАЦЮЮЧОМУ TV:                                             │
│   dropbear listens on :2222 (SSH pubkey-only)                │
│   runs as uid=0, context=User, full capabilities             │
└─────────────────────────────────────────────────────────────┘
       ↓
┌─────────────────────────────────────────────────────────────┐
│ З NAS/ноута:                                                 │
│   ssh -i key -p 2222 root@TV → bash as root                  │
└─────────────────────────────────────────────────────────────┘
```

### Чому саме такий шлях

**AT-HUB.service** — це stock Samsung systemd-юніт, який:
- Живе в read-only `/usr/lib/systemd/system/` → сам файл не можна змінити
- Має `WantedBy=starter.target` → **автоматично запускається при кожному буті**
- НЕ має `User=` → виконується з UID 0 (повний root)
- Його `ExecStart=/opt/etc/parseinfo.sh &` вказує на **писучу** VDFS-партицію `/opt` → ось де наш хук

Отже заміна одного файлу на writable fs дає root автоматично при буті. **Без патчингу raw-blocks, без партицій, без ризику зіпсувати bootloader.**

### Чому gawk, не bash

На Tizen зроблено **UEP (Unsigned Executable Prevention)** — kernel-рівневий блокувальник непідписаних бінарників. `/bin/bash` і `/bin/sh` мають link проти `libkUEPUser.so`, яка чекає підпис `##UEP...` у скрипт-файлі (сам stock parseinfo.sh такий підпис має — він теж "непідписаний" для kernel, але має fake-signature trailer для libkUEPUser.so hook в бінарниках інтерпретаторів).

`/usr/bin/gawk`:
- **НЕ лінкований з libkUEPUser.so** (`ldd /usr/bin/gawk | grep uep` → нічого)
- Підписаний системно, kernel UEP його акцептує
- `BEGIN { ... exit }` виконує логіку без читання script-файлу повторно → `#!/usr/bin/gawk -f` script проходить
- `system("cat /path/to/runner.sh | bash")` — stdin-pipe не триггерить libkUEPUser.so bash-hook (бо skrypt не є file-arg)

### Чому Dropbear не запускається просто так

На Tizen 9.0/rosel UEP навіть для root-процесу блокує непідписані native ELF. Але є лазівка (open issue chris-ritsen/samsung-tv-root#17): **UEP приймає exec через read-only VDFS mount view**:

```sh
mkdir -p /opt/persist /opt/persist-ro
mount --bind /opt/persist /opt/persist-ro
mount -o remount,ro,bind /opt/persist-ro
# → /opt/persist-ro — view на /opt/persist з fs type vdfs, ro
# → /opt/persist-ro/dropbear — UEP пропускає
```

Нюанс: UEP кешує по (device, inode) + writable-state. Якщо спершу запустити бінарник через writable path (`/opt/persist/dropbear`) — UEP кешує як "writable" і наступний виклик через ro-view fail'нить. Отже **свіжі inode'и створюються у runner.sh `cat $MOD/dropbear > /opt/persist/dropbear.new && mv`** (атомарний replace).

### Чому FAKE_ROOT patch для Dropbear

Stock cross-compiled static dropbear (готовий binary з Alpine/release) на Tizen поводиться так:
```
[XXXX] Login attempt for nonexistent user
```

Причина: static dropbear використовує glibc getpwnam(), яка all'тер все одно підтягує NSS через dlopen. На Tizen 9.0 glibc 2.30 має `libnss_files.so.2` у `/usr/lib/`, але:
- Static dropbear скомпільований на glibc 2.35 → ABI incompatible NSS modules
- LD_LIBRARY_PATH не завжди доходить до forked children

**Рішення**: невеликий патч у `fill_passwd()` — якщо `getpwnam()` повертає NULL і username = `"root"` чи `"owner"`, підставляємо хардкоджений pw-struct (uid=0, home=/home/owner, shell=/bin/bash). Patch — у `dropbear-fakeroot/fakeroot.patch` (20 рядків).

## 🇺🇦 Крок за кроком: встановлення

### Передумови
1. TV доступний по SDB (Developer Mode увімкнений, Host PC IP вказаний на TV)
2. На хості: `samsung-tv-root` v0.0.13+ working (volatile root через archive-root)
3. HTTP-сервер на хості для передачі файлів на TV (бо `sdb push` блокує SMACK)

### Крок 1. Побудуйте пропатчений dropbear

```bash
# На Ubuntu 22.04/Debian — потрібно arm cross-compiler
apt install -y gcc-arm-linux-gnueabihf autoconf
bash dropbear-fakeroot/build.sh
# → /tmp/dropbear-build/dropbear-git/dropbear (928K, static ARM)
# → /tmp/dropbear-build/dropbear-git/dropbearkey
```

### Крок 2. Підготуйте модуль

```bash
cp dropbear-fakeroot/dropbear   at-hub-persistence/
cp dropbear-fakeroot/dropbearkey at-hub-persistence/
cp your-nas-pubkey.pub           at-hub-persistence/authorized_keys
```

### Крок 3. Запустіть HTTP-сервер

```bash
cd samsung-tv-at-hub-persistence
python3 -m http.server 18888
```

### Крок 4. З root-сесії на TV залийте модуль

```bash
NAS=192.168.88.4   # ваш хост
TV_MOD=/opt/usr/share/selfroot/modules/at-hub-persistence

tv-root "mkdir -p $TV_MOD /opt/usr/share/selfroot/backups /opt/usr/share/selfroot/evidence && \
  cd $TV_MOD && \
  for f in hook.awk runner.sh boot.sh dropbear dropbearkey authorized_keys; do \
    curl -sfLo \$f http://$NAS:18888/at-hub-persistence/\$f; \
  done && \
  chmod 755 hook.awk runner.sh boot.sh dropbear dropbearkey && \
  chmod 644 authorized_keys"
```

### Крок 5. Встановіть hook

```bash
tv-root "cd $TV_MOD && cat $TV_MOD/boot.sh | MODULE_DIR=$TV_MOD bash"
# → "at-hub-persistence: hook installed."
```

### Крок 6. Перевірте БЕЗ ребуту

```bash
tv-root "systemctl restart AT-HUB.service && sleep 6 && \
  tail /opt/usr/share/selfroot/evidence/at-hub.log && \
  cat /opt/usr/share/selfroot/evidence/selfroot-proof.txt"
# → має показати uid=0, ctx=System::Privileged, CapEff 0x3fffffffff
```

### Крок 7. SSH тест

```bash
ssh -i ~/.ssh/tv_spalnia_ed25519 -p 2222 root@192.168.88.39 'id; uname -a'
# → uid=0(root) gid=0(root) ...
# → Linux Samsung 5.4.261 ... armv7l GNU/Linux
```

### Крок 8. Ребут TV

```
- Вимкнути TV з пульта
- Включити назад
- Почекати ~15 секунд (boot-settle)
- ssh -p 2222 root@TV → знову root, без жодної команди з NAS
```

### Rollback

```bash
tv-root "cat /opt/usr/share/selfroot/backups/parseinfo.sh.stock > /opt/etc/parseinfo.sh"
# + ребут
```

## 🇺🇦 NAS-side backup

Опційно: демон на Synology/Xpenology, що моніторить TV і реакваєрить **volatile** root через `archive-root` як страховку, якщо AT-HUB раптом не піднявся (наприклад, після firmware update, який перевстановив /opt/etc/parseinfo.sh).

- `nas-host-tools/tv-root` — CLI wrapper (`tv-root <cmd>`, `tv-root probe`, `tv-root daemon-start/stop/status/log`)
- `nas-host-tools/tv-root-daemon.sh` — моніторить ping TV, при offline→online реакваєрить рут
- `nas-host-tools/tv-root-daemon-keepalive.sh` — крон-перевірка живості самого демона

Налаштування на Synology DSM:
```bash
# DSM scheduled task "bootup" event
INSERT INTO task (task_name, event, enable, owner, operation, operation_type, status) 
VALUES ('tv-root-daemon','bootup',1,0,'/path/to/tv-root-daemon.sh','script','{}');

# + cron кожні 5 хв (ре-start якщо впав)
*/5 * * * * root /path/to/tv-root-daemon-keepalive.sh
```

## 🇺🇦 Структура репо

```
.
├── README.md                             — цей файл
├── README.en.md                          — English mirror
├── at-hub-persistence/
│   ├── hook.awk                          — gawk-скрипт, заміна parseinfo.sh
│   ├── runner.sh                         — boot runner (SSH + UEP bypass)
│   ├── boot.sh                           — installer (sha256-verified)
│   └── authorized_keys.example
├── dropbear-fakeroot/
│   ├── fakeroot.patch                    — патч для dropbear/src/common-session.c
│   ├── localoptions.h                    — build options
│   └── build.sh                          — cross-compile ARM static
├── nas-host-tools/
│   ├── tv-root                           — CLI wrapper
│   ├── tv-root-daemon.sh                 — reacquire daemon
│   └── tv-root-daemon-keepalive.sh
└── docs/
    ├── our-journey.md                    — повний запис нашого шляху
    └── troubleshooting.md
```

## 🇺🇦 Тестовані моделі

| Модель | Tizen | Platform | Firmware | AT-HUB hook | SSH |
|---|---|---|---|---|---|
| QE65Q7F5AUXUA | 9.0 | rosel | T-RSLFDEUC-0090 | ✅ | ✅ |

> Поповнення — в [issues](https://github.com/alexbadcat/samsung-tv-at-hub-persistence/issues).

## Ліцензія / License

MIT. Код у цьому репо — наш; оригінали (`samsung-tv-root` apstream, `dropbear`) мають власні ліцензії.
