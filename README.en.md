# Samsung Tizen TV — Persistent Root + SSH (AT-HUB Hook)

> 🇺🇦 **Українська версія — [README.md](README.md)** (main)
> 🇬🇧 **English — this page**

## What this is

A full engineering walkthrough for obtaining **persistent root + SSH server** on a Samsung TV with Tizen OS, surviving every reboot with no host-side injection. Proven on `QE65Q7F5AUXUA` (Tizen 9.0, rosel platform, armv7l, firmware `T-RSLFDEUC-0090`).

Builds conceptually on two prior works, huge thanks to the authors:
- [chris-ritsen/samsung-tv-root](https://github.com/chris-ritsen/samsung-tv-root) — initial **volatile** root via SDB Developer Mode → .NET capability chain (`archive-root`)
- [levkropp/samsung-tv-root-untethered](https://github.com/levkropp/samsung-tv-root-untethered) — the **AT-HUB vendor service hook** idea for boot-persistent root (on Q60B/Tizen 6.5)

Our contribution:
- **Adapt the AT-HUB hook for Tizen 9.0/rosel** (same stock parseinfo.sh, same sha256 `c6369e7...` — the recipe transfers 1:1)
- **FAKE_ROOT patch for dropbear** — so a static-linked SSH server works on Tizen where static glibc NSS cannot resolve `root` via `/etc/passwd`
- **NAS-side backup daemon** — a host utility on Synology/Xpenology that monitors the TV and re-acquires volatile root via `archive-root` as a safety net if AT-HUB ever fails (e.g. firmware update rewrote `/opt`)
- **Detailed journal of our journey** from zero to working SSH

## What you get

After full install:
```bash
# From any LAN host (NAS, laptop, phone):
ssh -i ~/.ssh/tv_spalnia_ed25519 -p 2222 root@192.168.88.39
# → root shell on TV, UID 0, full CapEff 0x3fffffffff
```

Works **after any TV reboot** — no NAS involvement, no SDB, no Developer Mode (Dev Mode is only needed for the initial install).

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ ON TV BOOT:                                                  │
│   systemd starter.target                                     │
│    └─ AT-HUB.service (vendor unit, no User= → root)         │
│        └─ /opt/etc/parseinfo.sh  ← OUR gawk hook             │
│            ├─ vendor target_version write (preserved 1:1)   │
│            └─ system("cat runner.sh | bash")                 │
│                ├─ VDFS read-only bind /opt/persist           │
│                ├─ dropbear host-keys gen (if missing)        │
│                ├─ authorized_keys deploy                     │
│                └─ systemd-run --scope dropbear :2222         │
└─────────────────────────────────────────────────────────────┘
       ↓
┌─────────────────────────────────────────────────────────────┐
│ ON RUNNING TV:                                               │
│   dropbear listens on :2222 (SSH pubkey-only)                │
│   runs as uid=0, context=User, full capabilities             │
└─────────────────────────────────────────────────────────────┘
       ↓
┌─────────────────────────────────────────────────────────────┐
│ FROM NAS / laptop:                                           │
│   ssh -i key -p 2222 root@TV → bash as root                  │
└─────────────────────────────────────────────────────────────┘
```

### Why this path

**AT-HUB.service** is a stock Samsung systemd unit:
- Lives in read-only `/usr/lib/systemd/system/` → the service file itself cannot be modified
- `WantedBy=starter.target` → **starts automatically at every boot**
- No `User=` → runs with UID 0 (full root)
- `ExecStart=/opt/etc/parseinfo.sh &` points to a **writable** VDFS partition `/opt` → that's where our hook goes

So replacing a single file on writable fs gives automatic root at boot. **No raw-block patching, no bootloader risk.**

### Why gawk instead of bash

Tizen has **UEP (Unsigned Executable Prevention)** — a kernel-level block for unsigned binaries. `/bin/bash` and `/bin/sh` are linked against `libkUEPUser.so`, which expects a `##UEP...` signature trailer in script files (stock parseinfo.sh has such a trailer — it's there precisely for this reason).

`/usr/bin/gawk`:
- **NOT linked against libkUEPUser.so** (`ldd /usr/bin/gawk | grep uep` → empty)
- System-signed, kernel UEP accepts it
- `BEGIN { ... exit }` runs the logic without re-reading the script file → `#!/usr/bin/gawk -f` script passes
- `system("cat /path/to/runner.sh | bash")` — stdin pipe does NOT trigger libkUEPUser.so bash hook (since the script isn't a file arg)

### Why Dropbear doesn't just run

On Tizen 9.0/rosel, UEP blocks unsigned native ELF even for root. But there's a loophole (chris-ritsen#17): **UEP accepts exec via a read-only VDFS mount view**:

```sh
mkdir -p /opt/persist /opt/persist-ro
mount --bind /opt/persist /opt/persist-ro
mount -o remount,ro,bind /opt/persist-ro
```

Gotcha: UEP caches by (device, inode) + writable state. If you exec a binary via its writable path first, UEP caches it as "writable" and subsequent exec via ro-view fails. So `runner.sh` always creates fresh inodes:
```sh
cat $MOD/dropbear > /opt/persist/dropbear.new && mv /opt/persist/dropbear.new /opt/persist/dropbear
```

### Why FAKE_ROOT patch for Dropbear

A stock cross-compiled static dropbear on Tizen fails with:
```
Login attempt for nonexistent user
```

Reason: static dropbear uses glibc `getpwnam()` which still tries to `dlopen("libnss_files.so.2")`. Tizen 9.0 has glibc 2.30 in `/usr/lib/`, but:
- Our static dropbear was built on glibc 2.35 → NSS modules ABI incompatible
- LD_LIBRARY_PATH doesn't reliably propagate to forked children

**Solution**: a small patch in `fill_passwd()` — if `getpwnam()` returns NULL and the username is `"root"` or `"owner"`, substitute a hardcoded pw-struct (uid=0, home=/home/owner, shell=/bin/bash). See `dropbear-fakeroot/fakeroot.patch` (20 lines).

## Step-by-step install

### Prerequisites
1. TV reachable via SDB (Developer Mode enabled, Host PC IP set)
2. `samsung-tv-root` v0.0.13+ working on host (volatile root via archive-root)
3. HTTP server on host for file transfer (SMACK blocks `sdb push`)

### Step 1. Build the patched dropbear

```bash
# On Ubuntu 22.04/Debian — needs arm cross-compiler
apt install -y gcc-arm-linux-gnueabihf autoconf
bash dropbear-fakeroot/build.sh
```

### Step 2. Prepare the module

```bash
cp dropbear-fakeroot/dropbear   at-hub-persistence/
cp dropbear-fakeroot/dropbearkey at-hub-persistence/
cp your-nas-pubkey.pub           at-hub-persistence/authorized_keys
```

### Step 3. Start HTTP server

```bash
cd samsung-tv-at-hub-persistence
python3 -m http.server 18888
```

### Step 4. Deploy module on TV

```bash
NAS=192.168.88.4
TV_MOD=/opt/usr/share/selfroot/modules/at-hub-persistence

tv-root "mkdir -p $TV_MOD /opt/usr/share/selfroot/backups /opt/usr/share/selfroot/evidence && \
  cd $TV_MOD && \
  for f in hook.awk runner.sh boot.sh dropbear dropbearkey authorized_keys; do \
    curl -sfLo \$f http://$NAS:18888/at-hub-persistence/\$f; \
  done && \
  chmod 755 hook.awk runner.sh boot.sh dropbear dropbearkey && \
  chmod 644 authorized_keys"
```

### Step 5. Install hook

```bash
tv-root "cd $TV_MOD && cat $TV_MOD/boot.sh | MODULE_DIR=$TV_MOD bash"
# → "at-hub-persistence: hook installed."
```

### Step 6. Verify without reboot

```bash
tv-root "systemctl restart AT-HUB.service && sleep 6 && \
  tail /opt/usr/share/selfroot/evidence/at-hub.log && \
  cat /opt/usr/share/selfroot/evidence/selfroot-proof.txt"
```

### Step 7. SSH test

```bash
ssh -i ~/.ssh/tv_spalnia_ed25519 -p 2222 root@192.168.88.39 'id; uname -a'
```

### Step 8. Reboot TV

- Power off TV from remote
- Power back on
- Wait ~15 seconds (boot-settle)
- `ssh -p 2222 root@TV` → root again, no NAS involvement

### Rollback

```bash
tv-root "cat /opt/usr/share/selfroot/backups/parseinfo.sh.stock > /opt/etc/parseinfo.sh"
# + reboot
```

## NAS-side backup

Optional: a daemon on Synology/Xpenology that monitors the TV and re-acquires **volatile** root via `archive-root` as a safety net.

- `nas-host-tools/tv-root` — CLI wrapper
- `nas-host-tools/tv-root-daemon.sh` — monitors ping, re-acquires on offline→online
- `nas-host-tools/tv-root-daemon-keepalive.sh` — cron keepalive

Synology DSM setup:
```bash
# DSM scheduled task on bootup event
INSERT INTO task (task_name, event, enable, owner, operation, operation_type, status)
VALUES ('tv-root-daemon','bootup',1,0,'/path/to/tv-root-daemon.sh','script','{}');

# + cron every 5 min
*/5 * * * * root /path/to/tv-root-daemon-keepalive.sh
```

## Repo layout

```
.
├── README.md                             — this file (Ukrainian)
├── README.en.md                          — English mirror
├── at-hub-persistence/                   — TV-side module
│   ├── hook.awk                          — gawk script, parseinfo.sh replacement
│   ├── runner.sh                         — boot runner (SSH + UEP bypass)
│   ├── boot.sh                           — installer (sha256-verified)
│   └── authorized_keys.example
├── dropbear-fakeroot/                    — build artifacts
│   ├── fakeroot.patch                    — patch for dropbear/src/common-session.c
│   ├── localoptions.h                    — build options
│   └── build.sh                          — cross-compile ARM static
├── nas-host-tools/                       — NAS-side utilities
│   ├── tv-root                           — CLI wrapper
│   ├── tv-root-daemon.sh                 — reacquire daemon
│   └── tv-root-daemon-keepalive.sh
└── docs/
    ├── our-journey.md                    — detailed journey log
    └── troubleshooting.md
```

## Tested models

| Model | Tizen | Platform | Firmware | AT-HUB hook | SSH |
|---|---|---|---|---|---|
| QE65Q7F5AUXUA | 9.0 | rosel | T-RSLFDEUC-0090 | ✅ | ✅ |

> Additions welcome via [issues](https://github.com/alexbadcat/samsung-tv-at-hub-persistence/issues).

## License

MIT. Code in this repo is ours; upstream (`samsung-tv-root`, `dropbear`) carry their own licenses.
