#!/bin/sh
# nas share — samba is stubbed (testparm/smbpasswd/pdbedit/rc-service); the
# managed-file surgery, the gates and the user bookkeeping are real.
. "$(dirname "$0")/harness.sh"

SC=/etc/samba/mountnas-shares.conf
SMB=/etc/samba/smb.conf
stub lbu ':'
stub rc-service 'exit 0'          # samba "running"
stub chown ':'
stub iptables 'exit 1'            # ufw chains absent (no fw hint) by default
# mountpoint: /mnt/nasdata mounted; /not-mounted is not
stub mountpoint 'case "$2" in /not-mounted*) exit 1 ;; *) exit 0 ;; esac'
# testparm: exit per flag file; -s output = global + OUR file + optional
# hand-written section (models the include resolution samba itself does).
# testparm-bad = always broken (exercises the add-time PRE-check);
# testparm-bad-edit = broken only once the managed file holds [broken]
# (passes the pre-check, fails the post-edit gate).
stub testparm '[ -e /tmp/testparm-bad ] && exit 1
[ -e /tmp/testparm-bad-edit ] && grep -q "^\[broken\]" /etc/samba/mountnas-shares.conf && exit 1
echo "[global]"
cat /etc/samba/mountnas-shares.conf 2>/dev/null
[ -e /tmp/manual-share ] && printf "[handmade]\n\tpath = /mnt/nasdata/hand\n\tvalid users = hanna\n"
exit 0'
# smbpasswd/pdbedit/adduser/deluser keep a user list in /tmp/smb-users
stub smbpasswd 'case "$1" in
	-a|-s) u=""; for a in "$@"; do u=$a; done; echo "$u" >> /tmp/smb-users ;;
	-x) u=$2; grep -vx "$u" /tmp/smb-users > /tmp/smb-users.n 2>/dev/null; mv /tmp/smb-users.n /tmp/smb-users ;;
	*) : ;;   # passwd change
esac'
stub pdbedit 'sed "s/$/:1000:/" /tmp/smb-users 2>/dev/null'
stub adduser 'for a in "$@"; do u=$a; done; echo "$u" >> /tmp/sys-users'
stub deluser 'grep -vx "$1" /tmp/sys-users > /tmp/sys-users.n 2>/dev/null; mv /tmp/sys-users.n /tmp/sys-users'
stub id 'grep -qx "$1" /tmp/sys-users 2>/dev/null'

seed() {
	mkdir -p /etc/samba /mnt/nasdata/media
	printf '[global]\n   workgroup = WORKGROUP\ninclude = %s\n' "$SC" > "$SMB"
	printf '; managed by nas share\n' > "$SC"
	: > /tmp/smb-users; : > /tmp/sys-users
	rm -f /tmp/testparm-bad /tmp/testparm-bad-edit /tmp/manual-share
}
# 'nas share add' answers (the seed pre-creates the dir, so there is no
# create-dir prompt): access-mode / user name / rw-or-ro — via stdin
add_share() {   # $1=name $2=path $3=user $4=mode(1=rw,2=ro)
	OUT=$(printf '1\n%s\n%s\n' "$3" "${4:-1}" | /usr/sbin/nas share add "$1" "$2" 2>&1); RC=$?
}

t "no shares: list hints at add"
seed; run_nas share
assert_rc 0
assert_match 'no shares yet' "$OUT"

t "user add: system user + smbpasswd, never a password on the command line"
seed
printf 'pw\npw\n' | /usr/sbin/nas share user add alice >/dev/null 2>&1
grep -qx alice /tmp/smb-users || fail "smbpasswd -a not called for alice"
grep -qx alice /tmp/sys-users || fail "adduser not called for alice"
run_nas share user list
assert_match 'alice.*\(on no share\)' "$OUT"

t "add: creates the section, force user, reaches testparm gate, reloads"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
assert_rc 0
assert_match 'share \[media\] -> /mnt/nasdata/media \(alice, rw\)' "$OUT"
assert_match '^\[media\]$' "$(cat $SC)"
assert_match 'valid users = alice' "$(cat $SC)"
assert_match 'force user = alice' "$(cat $SC)"
assert_match 'read only = no' "$(cat $SC)"
assert_nomatch 'read list' "$(cat $SC)" "rw share must carry no read list"

t "add --ro path: the user lands on the read list"
seed; echo bob >> /tmp/smb-users; echo bob >> /tmp/sys-users
add_share docs /mnt/nasdata/media bob 2
assert_rc 0
assert_match 'read list = bob' "$(cat $SC)"

t "add: guest share is read-only by default"
seed
OUT=$(printf '2\n' | /usr/sbin/nas share add pub /mnt/nasdata/media 2>&1); RC=$?
assert_rc 0
assert_match 'guest ok = yes' "$(cat $SC)"
assert_match 'read only = yes' "$(cat $SC)"
assert_match 'force user = nobody' "$(cat $SC)"

t "add refuses: bad name, reserved name, duplicate, RAM-root path"
seed
run_nas share add 'bad name' /mnt/nasdata/media
assert_rc 1; assert_match 'letters, digits' "$OUT"
run_nas share add global /mnt/nasdata/media
assert_rc 1; assert_match 'reserved' "$OUT"
echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
add_share media /mnt/nasdata/media alice 1
assert_rc 1; assert_match 'already exists' "$OUT"
run_nas share add tmpshare /not-mounted/x
assert_rc 1; assert_match 'not on a mounted disk' "$OUT"

t "the testparm gate restores the previous file byte-for-byte"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
before=$(cat "$SC")
: > /tmp/testparm-bad-edit
add_share broken /mnt/nasdata/media alice 1
assert_rc 1
assert_match 'restored unchanged' "$OUT"
assert_eq "$before" "$(cat $SC)" "file must be byte-identical after a rejected edit"
rm -f /tmp/testparm-bad-edit

t "add refuses up front when smb.conf is ALREADY broken (right suspect)"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
: > /tmp/testparm-bad
add_share media /mnt/nasdata/media alice 1
assert_rc 1
assert_match 'already invalid' "$OUT" "a pre-broken smb.conf must not blame the new share"
rm -f /tmp/testparm-bad

t "allow adds to valid users; allow --ro also to read list; idempotent"
seed; printf 'alice\nbob\n' >> /tmp/smb-users; printf 'alice\nbob\n' >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
run_nas share allow media bob --ro
assert_rc 0
assert_match 'valid users = alice, bob' "$(cat $SC)"
assert_match 'read list = bob' "$(cat $SC)"
run_nas share allow media bob --ro
assert_eq 1 "$(grep -c 'valid users' $SC)" "no duplicate keys"
assert_match 'valid users = alice, bob' "$(cat $SC)"

t "allow refuses an unknown user and a hand-written share"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
run_nas share allow media ghost
assert_rc 1; assert_match "no samba user 'ghost'" "$OUT"
: > /tmp/manual-share
run_nas share allow handmade alice
assert_rc 1; assert_match 'no managed share' "$OUT"

t "revoke removes from both lists; last user leaves a loud warning"
seed; printf 'alice\nbob\n' >> /tmp/smb-users; printf 'alice\nbob\n' >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
run_nas share allow media bob --ro
run_nas share revoke media bob
assert_rc 0
assert_match 'valid users = alice' "$(cat $SC)"
assert_nomatch 'read list' "$(cat $SC)"
run_nas share revoke media alice
assert_match 'NO user list' "$OUT"
assert_nomatch 'valid users' "$(cat $SC)"

t "list shows managed and hand-written shares with their access"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
: > /tmp/manual-share
run_nas share list
assert_rc 0
assert_match '\[managed\] media.*alice' "$OUT"
assert_match '\[manual \] handmade.*hanna' "$OUT"

t "remove deletes only the section and offers the orphaned user"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
OUT=$(printf 'y\n' | /usr/sbin/nas share remove media 2>&1); RC=$?
assert_rc 0
assert_match 'share \[media\] removed' "$OUT"
assert_match 'directory .* untouched' "$OUT"
assert_nomatch '^\[media\]$' "$(cat $SC)"
grep -qx alice /tmp/smb-users && fail "orphaned user not removed after 'y'"

t "remove keeps the user on 'n' and when still on another share"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
add_share extra /mnt/nasdata/media alice 1
OUT=$(printf 'y\n' | /usr/sbin/nas share remove extra 2>&1)
grep -qx alice /tmp/smb-users || fail "user deleted although still on [media]"
OUT=$(printf 'n\n' | /usr/sbin/nas share remove media 2>&1)
grep -qx alice /tmp/smb-users || fail "user deleted despite answering n"

t "delete is an alias of remove"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
OUT=$(printf 'n\n' | /usr/sbin/nas share delete media 2>&1); RC=$?
assert_rc 0
assert_nomatch '^\[media\]$' "$(cat $SC)"

t "user remove: granted user needs the typed double opt-in"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
OUT=$(printf 'wrong\n' | /usr/sbin/nas share user remove alice 2>&1); RC=$?
assert_rc 1
assert_match 'still granted' "$OUT"
grep -qx alice /tmp/smb-users || fail "user removed on a WRONG confirmation"
OUT=$(printf 'alice\n' | /usr/sbin/nas share user remove alice 2>&1); RC=$?
assert_rc 0
grep -qx alice /tmp/smb-users && fail "user not removed after correct confirmation"

t "revoke of a user not on the share is a reported no-op"
seed; printf 'alice\nbob\n' >> /tmp/smb-users; printf 'alice\nbob\n' >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
run_nas share revoke media bob
assert_rc 0
assert_match 'not on \[media\]' "$OUT"
assert_nomatch 'NO user list' "$OUT" "an unchanged share must not warn it is open"
assert_match 'valid users = alice' "$(cat $SC)"

t "user remove deletes only SMB-shaped accounts; login accounts are kept"
seed
printf 'realuser\nsmbonly\n' >> /tmp/smb-users; printf 'realuser\nsmbonly\n' >> /tmp/sys-users
echo 'realuser:x:1001:1001::/home/realuser:/bin/sh' >> /etc/passwd
echo 'smbonly:x:1002:1002::/:/sbin/nologin' >> /etc/passwd
run_nas share user remove realuser
assert_rc 0
assert_match 'KEPT' "$OUT"
grep -qx realuser /tmp/sys-users || fail "login account deleted — its SSH access died with it"
run_nas share user remove smbonly
assert_rc 0
grep -qx smbonly /tmp/sys-users && fail "SMB-only account not deleted"
sed -i '/^realuser:/d; /^smbonly:/d' /etc/passwd

t "uppercase share names are refused (samba section names fold case)"
seed
run_nas share add Global /mnt/nasdata/media
assert_rc 1
assert_match 'lowercase' "$OUT" "'Global' would merge into [global] as service defaults"

t "a relative path and a dash-leading user are rejected outright"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
run_nas share add rel foo
assert_rc 1
assert_match 'not on a mounted disk' "$OUT" "relative paths must never hang the walk"
add_share media /mnt/nasdata/media alice 1
run_nas share revoke media -x
assert_rc 1
assert_match "invalid user name '-x'" "$OUT" "a dash arg must not reach grep and wipe the ACL"
assert_match 'valid users = alice' "$(cat $SC)" "ACL untouched after the rejected revoke"
run_nas share allow media -r
assert_rc 1

t "the force user is protected: remove needs the typed confirm even off the lists"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
run_nas share revoke media alice          # off valid users, still force user
assert_match "force user" "$OUT"
OUT=$(printf 'wrong\n' | /usr/sbin/nas share user remove alice 2>&1); RC=$?
assert_rc 1
assert_match 'still granted' "$OUT" "force user must count as granted"
grep -qx alice /tmp/smb-users || fail "force-user account deleted — the share is bricked"

t "the include lands INSIDE [global], before hand-written sections"
seed
# an upgraded box: smb.conf ENDS with a hand-written share (the case where
# an EOF append would be service-scoped and samba would IGNORE the include)
printf '[global]\n   workgroup = W\n\n[handrolled]\n   path = /mnt/nasdata/media\n' > "$SMB"
echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
assert_rc 0
inc_ln=$(grep -n "include = $SC" "$SMB" | cut -d: -f1 | head -n1)
sec_ln=$(grep -n '^\[handrolled\]' "$SMB" | cut -d: -f1)
[ "$inc_ln" -lt "$sec_ln" ] || fail "include appended after a [section] — samba ignores it there (line $inc_ln vs $sec_ln)"

t "list tags a guest share read-only even though testparm omits defaults"
seed
OUT=$(printf '2\n' | /usr/sbin/nas share add pub /mnt/nasdata/media 2>&1)
run_nas share list
assert_match 'pub.*guest.*\[read-only\]' "$OUT"

t "hand-written share removal is refused with directions"
seed; : > /tmp/manual-share
run_nas share remove handmade
assert_rc 1
assert_match 'hand-written share' "$OUT"
assert_match 'never edits your smb.conf shares' "$OUT"

t "firewall active without a samba rule warns on add"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
stub iptables 'exit 0'            # ufw chains loaded
stub ufw 'echo "22/tcp ALLOW Anywhere"'
add_share media /mnt/nasdata/media alice 1
assert_match 'firewall is ACTIVE but Samba is not allowed' "$OUT"
assert_match 'ufw allow CIFS' "$OUT"
stub ufw 'echo "CIFS ALLOW Anywhere"'
add_share second /mnt/nasdata/media alice 1
assert_nomatch 'Samba is not allowed' "$OUT" "no warning once CIFS is allowed"
stub iptables 'exit 1'

t "include line is appended once for boxes that upgraded into the feature"
seed
printf '[global]\n   workgroup = W\n' > "$SMB"   # no include (old box)
echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
add_share media /mnt/nasdata/media alice 1
assert_rc 0
assert_eq 1 "$(grep -c "include = $SC" "$SMB")" "include appended exactly once"
add_share more /mnt/nasdata/media alice 1
assert_eq 1 "$(grep -c "include = $SC" "$SMB")" "second add must not duplicate it"

t "unsaved changes warn (persistence honesty)"
seed; echo alice >> /tmp/smb-users; echo alice >> /tmp/sys-users
stub lbu 'echo "M etc/samba/mountnas-shares.conf"'
add_share media /mnt/nasdata/media alice 1
assert_match 'NOT saved' "$OUT"
stub lbu ':'

finish
