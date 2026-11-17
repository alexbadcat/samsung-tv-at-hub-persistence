# Troubleshooting

## "Login attempt for nonexistent user"
Causes the dropbear log to print this when SSH client connects.
→ You're using a stock cross-compiled dropbear. Build the FAKE_ROOT-patched version (`dropbear-fakeroot/build.sh`).

## "Permission denied (publickey)"
- Check `/home/owner/.ssh/authorized_keys` owner is UID 0 (`chown 0:0`)
- Check `/home/owner` mode is 755 (dropbear strictmodes check)
- Check your key is in `authorized_keys` (one per line, no CR)
- Verify key-type is supported (ed25519/RSA default in dropbear 2026.94)

## Dropbear "Early exit: Terminated by signal"
AT-HUB.service kills child processes when ExecStart completes.
→ Launch dropbear via `systemd-run --scope --unit=tv-sshd`.

## "Operation not permitted" on exec
UEP blocked an unsigned ELF.
→ Must exec through read-only VDFS view (`/opt/persist-ro/`), with a fresh inode (never executed through the writable path first).

## AT-HUB hook not firing on boot
```sh
tv-root "systemctl cat AT-HUB.service"
tv-root "systemctl is-enabled AT-HUB.service"
```
AT-HUB.service may report `disabled`, but the vendor `starter.target.wants/` symlink still starts it at boot.

## After firmware update, root gone
A firmware update may rewrite `/opt/etc/parseinfo.sh` back to stock.
→ NAS-side daemon (`tv-root-daemon`) will re-acquire volatile root; reinstall the hook via `boot.sh`.
