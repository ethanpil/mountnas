# shellcheck shell=sh
# nas share / nas shares
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas share — first-class Samba shares WITHOUT hand-editing smb.conf, and
# without ever touching what the user hand-edited there. The command owns
# exactly ONE generated file ($SHARES_CONF, included from smb.conf); every
# mutation is validated by testparm BEFORE samba sees it, and a failed parse
# restores the previous file byte-for-byte. Design record: SPEC-roadmap-4.md.
#
# Access model, two levels by design (an ACL matrix is hand-edit territory):
#   - the share's user list ('valid users')          -> allow / revoke
#   - a per-user read-only exception ('read list')   -> allow --ro
# Writes act as the share's owner via 'force user' — the standard home-NAS
# pattern that lets several allowed users write one tree without a group
# dance; access is still gated per-user by 'valid users' + smbpasswd.
SHARES_CONF=/etc/samba/mountnas-shares.conf
SMB_CONF=/etc/samba/smb.conf

# smb.conf must include our file once. The seed ships the include from this
# release on; a box that upgraded into the feature gets it appended HERE —
# one marker-tagged line, the only smb.conf edit this command ever makes.
_share_ensure_include() {
	grep -q "include = $SHARES_CONF" "$SMB_CONF" 2>/dev/null && return 0
	printf '\n# managed shares (nas share) — keep this include; edit shares via the command\ninclude = %s\n' \
		"$SHARES_CONF" >> "$SMB_CONF" || { bad "cannot update $SMB_CONF"; return 1; }
	hint "added 'include = $SHARES_CONF' to smb.conf"
}
# every section name in OUR file (never parses hand-written smb.conf shares)
_share_names() {
	sed -n 's/^\[\(.*\)\]$/\1/p' "$SHARES_CONF" 2>/dev/null
}
# Keys are matched as the WHOLE phrase before '=' ("valid users", not the
# first word): a field comparison ($1 == k) silently never matches two-word
# samba keys, and _share_set then appends a duplicate instead of replacing.
_share_get() {   # $1=share $2=key -> value ("" if absent)
	awk -v s="[$1]" -v k="$2" '
		$0 == s { in_s = 1; next }
		/^\[/   { in_s = 0 }
		in_s && $0 ~ ("^[ \t]*" k "[ \t]*=") { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
	' "$SHARES_CONF" 2>/dev/null
}
# rewrite one key inside one section (the section exists; the key may not)
_share_set() {   # $1=share $2=key $3=value
	local tmpf
	tmpf=$(mktemp) || return 1
	awk -v s="[$1]" -v k="$2" -v v="$3" '
		$0 == s { in_s = 1; print; next }
		/^\[/   { if (in_s && !done) { printf "   %s = %s\n", k, v; done = 1 }; in_s = 0 }
		in_s && $0 ~ ("^[ \t]*" k "[ \t]*=") { if (!done) { printf "   %s = %s\n", k, v; done = 1 }; next }
		{ print }
		END { if (in_s && !done) printf "   %s = %s\n", k, v }
	' "$SHARES_CONF" > "$tmpf" || { rm -f "$tmpf"; return 1; }
	cat "$tmpf" > "$SHARES_CONF" && rm -f "$tmpf"
}
_share_drop_key() {   # $1=share $2=key
	local tmpf
	tmpf=$(mktemp) || return 1
	awk -v s="[$1]" -v k="$2" '
		$0 == s { in_s = 1; print; next }
		/^\[/   { in_s = 0 }
		in_s && $0 ~ ("^[ \t]*" k "[ \t]*=") { next }
		{ print }
	' "$SHARES_CONF" > "$tmpf" || { rm -f "$tmpf"; return 1; }
	cat "$tmpf" > "$SHARES_CONF" && rm -f "$tmpf"
}
# validate with testparm, restore the previous bytes on failure. EVERY
# mutation goes through this gate — a garbled config can therefore reach
# neither samba nor the next boot (the backup is taken before the edit by
# the caller; $1 = that backup file).
_share_gate() {   # $1=pre-edit backup of $SHARES_CONF
	if testparm -s "$SMB_CONF" >/dev/null 2>&1; then
		rm -f "$1"
		return 0
	fi
	cat "$1" > "$SHARES_CONF"; rm -f "$1"
	bad "samba rejected the change (testparm) — $SHARES_CONF restored unchanged"
	return 1
}
_share_reload() {
	if rc-service samba status >/dev/null 2>&1; then
		rc-service samba reload >/dev/null 2>&1 || rc-service samba restart >/dev/null 2>&1 \
			|| warn "samba reload failed — check: rc-service samba status"
	else
		hint "samba is not running (it starts once the data disk is up: nas restart)"
	fi
}
_share_unsaved() {
	# an explicit if: the && form would leak grep's rc=1 (nothing unsaved,
	# the COMMON case) as the caller's return value
	if lbu status 2>/dev/null | grep -q 'etc/samba'; then
		warn "share changes are NOT saved — gone after a reboot unless you run: nas commit"
	fi
	return 0
}
# a share path must sit on a mounted disk: on this diskless box a path on
# the RAM root is the classic footgun ('nas status' fails on it too)
_share_path_ok() {
	local p
	p=$1
	[ -d "$p" ] || p=$(dirname "$p")
	while [ "$p" != "/" ]; do
		mountpoint -q "$p" 2>/dev/null && return 0
		p=$(dirname "$p")
	done
	return 1
}
# the firewall check the maintainer asked for: an ACTIVE ufw with no samba
# rule means the share works from localhost and nowhere else — say so now,
# not after an hour of client-side debugging
_share_fw_hint() {
	iptables -nL ufw-user-input >/dev/null 2>&1 || return 0
	ufw status 2>/dev/null | grep -qiE '445|CIFS|Samba' && return 0
	warn "the firewall is ACTIVE but Samba is not allowed — clients cannot connect."
	warn "Allow it, then save:  ufw allow CIFS && nas commit"
}
# smbpasswd wrapper: interactive on a tty; -s (stdin) otherwise so scripts
# and tests can pipe the password. Never takes the password as an argument —
# arguments land in shell history and process listings.
_share_smbpasswd() {   # $@ passed through (-a <user> | <user>)
	if [ -t 0 ]; then smbpasswd "$@"; else smbpasswd -s "$@"; fi
}
# every user granted on any share: managed sections + hand-written smb.conf
# ones (via testparm, which resolves the include so both kinds appear)
_share_all_granted() {
	testparm -s "$SMB_CONF" 2>/dev/null \
		| sed -n 's/^[[:space:]]*valid users *= *//p; s/^[[:space:]]*read list *= *//p' \
		| tr ',' '\n' | tr -d '\t ' | grep -v '^@' | grep . | sort -u
}
_share_samba_users() {
	pdbedit -L 2>/dev/null | cut -d: -f1 | sort -u
}

cmd_share() {
	local sub name path u ro bak owner ans mode users lost
	sub=${1:-list}
	case "$sub" in
	list)
		hdr "shares (managed + hand-written; effective values via testparm)"
		testparm -s "$SMB_CONF" 2>/dev/null | awk '
			/^\[/ { sec = substr($0, 2, length($0) - 2); if (sec != "global") print "SHARE\t" sec; next }
			/^[[:space:]]*path *=/       { sub(/^[^=]*= */, ""); print "path\t" $0 }
			/^[[:space:]]*valid users *=/{ sub(/^[^=]*= */, ""); print "users\t" $0 }
			/^[[:space:]]*read list *=/  { sub(/^[^=]*= */, ""); print "ro\t" $0 }
			/^[[:space:]]*read only *=/  { sub(/^[^=]*= */, ""); print "readonly\t" $0 }
			/^[[:space:]]*guest ok *=/   { sub(/^[^=]*= */, ""); print "guest\t" $0 }
		' | awk -F'\t' -v managed="$(_share_names | tr '\n' ' ')" '
			$1 == "SHARE" {
				if (cur != "") emit()
				cur = $2; p = us = ro = ""; ronly = "No"; guest = "No"
				next
			}
			$1 == "path"     { p = $2 }
			$1 == "users"    { us = $2 }
			$1 == "ro"       { ro = $2 }
			$1 == "readonly" { ronly = $2 }
			$1 == "guest"    { guest = $2 }
			END { if (cur != "") emit() }
			function emit(   tag, acc) {
				tag = index(" " managed " ", " " cur " ") ? "managed" : "manual "
				if (guest == "Yes") acc = "guest"
				else acc = (us == "" ? "(no valid users — everyone with a samba login)" : us)
				printf "  [%s] %-16s %-30s %s%s%s\n", tag, cur, p, acc, \
					(ronly == "Yes" ? "  [read-only]" : ""), \
					(ro != "" ? "  [ro: " ro "]" : "")
			}'
		[ -n "$(_share_names)" ] || [ -n "$(testparm -s "$SMB_CONF" 2>/dev/null | grep -v '^\[global\]' | grep '^\[')" ] \
			|| hint "no shares yet — create one: nas share add <name> <path>"
		;;
	add)
		name=${2:-}; path=${3:-}
		[ -n "$name" ] && [ -n "$path" ] || { usage "nas share add <name> <path>"; return 1; }
		case "$name" in
			*[!A-Za-z0-9_-]*) bad "share names are letters, digits, _ and - only"; return 1 ;;
			global|homes|printers) bad "'$name' is a reserved samba section name"; return 1 ;;
		esac
		_share_names | grep -qx "$name" && { bad "share [$name] already exists (see: nas share)"; return 1; }
		testparm -s "$SMB_CONF" 2>/dev/null | grep -qx "\[$name\]" \
			&& { bad "a hand-written share [$name] exists in smb.conf — pick another name"; return 1; }
		_share_path_ok "$path" || {
			bad "$path is not on a mounted disk — a share on the RAM root vanishes at reboot"
			hint "mount the disk first (nas disks shows a paste-ready fstab line)"; return 1; }
		if [ ! -d "$path" ]; then
			printf '%s does not exist. Create it? [Y/n]: ' "$path"; IFS= read -r ans || ans=""
			case "$ans" in n|N) echo "Cancelled."; return 1 ;; esac
			mkdir -p "$path" || { bad "cannot create $path"; return 1; }
		fi
		# access: guest, an existing samba user, or a new one — asked, not
		# flagged. The prompts read stdin, so scripts can pipe the answers
		# (the same pattern the setup wizard uses).
		owner=""; mode=rw
		printf 'Access for [%s]:  [1] a user (recommended)  [2] guest (no password, read-only): ' "$name"
		IFS= read -r ans || ans=""
		if [ "$ans" = 2 ]; then
			owner=guest
		else
			printf 'Samba users:%s\n' "$(_share_samba_users | tr '\n' ' ' | sed 's/^/ /;s/ $//')"
			printf 'User name (existing, or a new one to create): '; IFS= read -r u || u=""
			[ -n "$u" ] || { bad "a user is required"; return 1; }
			if ! _share_samba_users | grep -qx "$u"; then
				cmd_share user add "$u" || return 1
			fi
			owner=$u
			printf 'Access for %s:  [1] read-write  [2] read-only: ' "$u"; IFS= read -r ans || ans=""
			[ "$ans" = 2 ] && mode=ro
		fi
		_share_ensure_include || return 1
		[ -f "$SHARES_CONF" ] || : > "$SHARES_CONF"
		bak=$(mktemp); cat "$SHARES_CONF" > "$bak"
		{
			printf '\n[%s]\n' "$name"
			printf '   ; managed by nas share — edit via the command, not by hand\n'
			printf '   path = %s\n' "$path"
			if [ "$owner" = guest ]; then
				printf '   guest ok = yes\n   read only = yes\n   force user = nobody\n'
			else
				printf '   valid users = %s\n' "$owner"
				[ "$mode" = ro ] && printf '   read list = %s\n' "$owner"
				printf '   read only = no\n   force user = %s\n' "$owner"
			fi
			printf '   browseable = yes\n'
		} >> "$SHARES_CONF"
		_share_gate "$bak" || return 1
		# a dir this command just created belongs to the share's owner so
		# writes work; a PRE-EXISTING dir keeps its ownership untouched
		[ "$owner" != guest ] && [ -z "$(ls -A "$path" 2>/dev/null)" ] && chown "$owner" "$path" 2>/dev/null
		_share_reload
		ok "share [$name] -> $path ($([ "$owner" = guest ] && echo 'guest, read-only' || echo "$owner, $mode"))"
		hint "reach it at \\\\\\\\$(hostname)\\\\$name  (or smb://$(hostname).local/$name)"
		_share_fw_hint
		_share_unsaved
		;;
	remove|delete)
		name=${2:-}
		[ -n "$name" ] || { usage "nas share remove <name>"; return 1; }
		_share_names | grep -qx "$name" || {
			if testparm -s "$SMB_CONF" 2>/dev/null | grep -qx "\[$name\]"; then
				bad "[$name] is a hand-written share in smb.conf — remove it there (this command never edits your smb.conf shares)"
			else
				bad "no managed share [$name] (see: nas share)"
			fi
			return 1; }
		users=$(_share_get "$name" "valid users" | tr ',' '\n' | tr -d ' ' | grep .)
		path=$(_share_get "$name" "path")
		bak=$(mktemp); cat "$SHARES_CONF" > "$bak"
		awk -v s="[$name]" '
			$0 == s { in_s = 1; next }
			/^\[/   { in_s = 0 }
			!in_s   { print }
		' "$SHARES_CONF" > "$SHARES_CONF.new" && cat "$SHARES_CONF.new" > "$SHARES_CONF"
		rm -f "$SHARES_CONF.new"
		_share_gate "$bak" || return 1
		_share_reload
		ok "share [$name] removed — the directory ($path) and its files are untouched"
		# a user this removal orphaned (on no other share) is offered up too
		for u in $users; do
			_share_all_granted | grep -qx "$u" && continue
			printf 'User %s is on no other share. Delete the user too? [y/N]: ' "$u"
			IFS= read -r ans || ans=""
			case "$ans" in
				y|Y) cmd_share user remove "$u" ;;
				*) hint "kept — remove later with: nas share user remove $u" ;;
			esac
		done
		_share_unsaved
		;;
	allow)
		name=${2:-}; u=${3:-}; ro=${4:-}
		[ -n "$name" ] && [ -n "$u" ] || { usage "nas share allow <name> <user> [--ro]"; return 1; }
		case "$ro" in ''|--ro) ;; *) usage "nas share allow <name> <user> [--ro]"; return 1 ;; esac
		_share_names | grep -qx "$name" || { bad "no managed share [$name] (hand-written shares stay hand-edited)"; return 1; }
		_share_samba_users | grep -qx "$u" || { bad "no samba user '$u' — create one: nas share user add $u"; return 1; }
		[ "$(_share_get "$name" "guest ok")" = yes ] && { bad "[$name] is a guest share — user grants do not apply"; return 1; }
		bak=$(mktemp); cat "$SHARES_CONF" > "$bak"
		users=$(_share_get "$name" "valid users")
		printf '%s' ", $users," | grep -q ", $u," || _share_set "$name" "valid users" "${users:+$users, }$u"
		if [ "$ro" = "--ro" ]; then
			users=$(_share_get "$name" "read list")
			printf '%s' ", $users," | grep -q ", $u," || _share_set "$name" "read list" "${users:+$users, }$u"
		fi
		_share_gate "$bak" || return 1
		_share_reload
		ok "$u -> [$name]${ro:+ (read-only)}"
		_share_unsaved
		;;
	revoke)
		name=${2:-}; u=${3:-}
		[ -n "$name" ] && [ -n "$u" ] || { usage "nas share revoke <name> <user>"; return 1; }
		_share_names | grep -qx "$name" || { bad "no managed share [$name]"; return 1; }
		bak=$(mktemp); cat "$SHARES_CONF" > "$bak"
		users=$(_share_get "$name" "valid users" | tr ',' '\n' | tr -d ' ' | grep -vx "$u" | paste -sd, - | sed 's/,/, /g')
		if [ -n "$users" ]; then _share_set "$name" "valid users" "$users"
		else _share_drop_key "$name" "valid users"
			warn "[$name] now has NO user list — every samba login can reach it; remove the share or allow a user"
		fi
		users=$(_share_get "$name" "read list" | tr ',' '\n' | tr -d ' ' | grep -vx "$u" | paste -sd, - | sed 's/,/, /g')
		if [ -n "$users" ]; then _share_set "$name" "read list" "$users"
		else _share_drop_key "$name" "read list"; fi
		_share_gate "$bak" || return 1
		_share_reload
		ok "$u revoked from [$name]"
		_share_unsaved
		;;
	user|users)
		case "${2:-list}" in
		list)
			hdr "samba users"
			lost=$(_share_all_granted)
			_share_samba_users | while IFS= read -r u; do
				if printf '%s\n' "$lost" | grep -qx "$u"; then
					printf '  %-20s\n' "$u"
				else
					printf '  %-20s (on no share)\n' "$u"
				fi
			done
			[ -n "$(_share_samba_users)" ] || hint "no samba users yet — nas share user add <name>"
			;;
		add)
			u=${3:-}
			[ -n "$u" ] || { usage "nas share user add <user>"; return 1; }
			case "$u" in *[!a-z0-9_-]*) bad "user names are lowercase letters, digits, _ and - only"; return 1 ;; esac
			# an SMB-only account: no shell, no home, Linux password locked —
			# the ONE password this user has is the samba one set right here
			if ! id "$u" >/dev/null 2>&1; then
				adduser -D -H -s /sbin/nologin "$u" || { bad "adduser $u failed"; return 1; }
			fi
			_share_smbpasswd -a "$u" || { bad "smbpasswd failed — user not enabled for samba"; return 1; }
			ok "samba user $u ready (grant a share: nas share allow <share> $u)"
			_share_unsaved
			;;
		passwd)
			u=${3:-}
			[ -n "$u" ] || { usage "nas share user passwd <user>"; return 1; }
			_share_samba_users | grep -qx "$u" || { bad "no samba user '$u'"; return 1; }
			_share_smbpasswd "$u" && ok "password changed for $u" && _share_unsaved
			;;
		remove)
			u=${3:-}
			[ -n "$u" ] || { usage "nas share user remove <user>"; return 1; }
			_share_samba_users | grep -qx "$u" || { bad "no samba user '$u'"; return 1; }
			if _share_all_granted | grep -qx "$u"; then
				warn "$u is still granted on a share — revoke first, or confirm to remove anyway"
				printf "Type the user name to confirm removal: "
				IFS= read -r ans || ans=""
				[ "$ans" = "$u" ] || { echo "Cancelled."; return 1; }
			fi
			smbpasswd -x "$u" >/dev/null 2>&1 || warn "smbpasswd -x $u failed (already gone?)"
			deluser "$u" >/dev/null 2>&1 || warn "deluser $u failed"
			ok "samba user $u removed (files owned by the user are untouched)"
			_share_unsaved
			;;
		*) usage "nas share user [list | add <u> | passwd <u> | remove <u>]"; return 1 ;;
		esac
		;;
	*) usage "nas share [list | add <name> <path> | remove <name> | allow <name> <u> [--ro] | revoke <name> <u> | user ...]"; return 1 ;;
	esac
}

# help page for 'nas share --help' / 'nas help share'
help_share() {
	cat <<EOF
nas share [list | add | remove | allow | revoke | user]   (alias: nas shares)
  Samba shares without hand-editing smb.conf. The command owns ONE
  generated file (/etc/samba/mountnas-shares.conf); shares you wrote in
  smb.conf by hand are never touched, but 'list' shows them too.
  list                      every share, its path, users and access
  add <name> <path>         create a share (asks: user or guest, rw/ro)
  remove <name>             remove a share; files stay (alias: delete)
  allow <name> <u> [--ro]   grant a user (optionally read-only)
  revoke <name> <u>         remove a user from a share
  user list                 samba users, and who is on no share
  user add <u>              SMB-only account (no shell) + samba password
  user passwd <u>           change a samba password
  user remove <u>           delete a samba user (asks when still granted)
  Every change is checked with testparm BEFORE samba sees it; a bad edit
  is rolled back automatically. IMPORTANT: like every /etc change, shares
  live in RAM until 'nas commit' (the command warns).
EOF
}
