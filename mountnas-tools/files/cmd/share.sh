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
	# ACTIVE include lines only: a user who commented the include out has
	# disabled managed shares on purpose — matching the commented line would
	# report success while the share is silently never served
	# spacing-insensitive: a user-normalized 'include=/etc/...' line is the
	# SAME include — matching only our exact spacing would append a second one
	awk -v want="include=$SHARES_CONF" '
		/^[ \t]*include[ \t]*=/ { line = $0; gsub(/[ \t]/, "", line); if (line == want) found = 1 }
		END { exit !found }
	' "$SMB_CONF" 2>/dev/null && return 0
	# The include MUST land in [global] context — BEFORE the first hand-
	# written [section]. Appended at EOF on a typical upgraded smb.conf
	# (which ends with a share section) samba classifies 'include' as a
	# global parameter in service context and IGNORES it: every managed
	# share would be silently invisible while the command reports success.
	# same-directory staging + rename: an atomic swap-in — 'cat > smb.conf'
	# would open a truncate-then-fail window over the user's whole config
	local tmpf
	tmpf="$SMB_CONF.mnas-new"
	awk -v inc="include = $SHARES_CONF" '
		!done && /^[ \t]*\[/ && $0 !~ /^[ \t]*\[global\]/ {
			print "# managed shares (nas share) — keep this include; edit shares via the command"
			print inc; print ""; done = 1
		}
		{ print }
		END { if (!done) {
			print "# managed shares (nas share) — keep this include; edit shares via the command"
			print inc } }
	' "$SMB_CONF" > "$tmpf" 2>/dev/null || { rm -f "$tmpf"; bad "cannot update $SMB_CONF"; return 1; }
	mv "$tmpf" "$SMB_CONF" || { rm -f "$tmpf"; bad "cannot update $SMB_CONF (rename failed)"; return 1; }
	hint "added 'include = $SHARES_CONF' to smb.conf (inside [global])"
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
_share_drop_section() {   # $1=share — remove the whole managed section
	local tmpf
	tmpf=$(mktemp) || return 1
	awk -v s="[$1]" '
		$0 == s { in_s = 1; next }
		/^\[/   { in_s = 0 }
		!in_s   { print }
	' "$SHARES_CONF" > "$tmpf" || { rm -f "$tmpf"; return 1; }
	cat "$tmpf" > "$SHARES_CONF" && rm -f "$tmpf"
}
# take the pre-edit byte backup every mutation restores from. An UNCHECKED
# mktemp here is the one way the gate could destroy what it protects: with
# bak="" the rollback's 'cat "" > file' truncates the managed config.
_share_begin() {
	local bak
	bak=$(mktemp) || return 1
	cat "$SHARES_CONF" > "$bak" || { rm -f "$bak"; return 1; }
	printf '%s' "$bak"
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
# failed mid-mutation rewrite: put the pre-edit bytes back and say so.
# _share_set/_share_drop_key leave the file untouched when THEY fail, but a
# multi-step edit (allow touches two keys) can die between steps — restore.
_share_abort() {   # $1=the _share_begin backup
	cat "$1" > "$SHARES_CONF"; rm -f "$1"
	bad "rewrite failed (RAM root full?) — nothing changed"
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
# a share path must sit on a MOUNTED DATA DISK. lib.sh's _path_on_disk is
# the single walk (it also detects the supervisor's read-only placeholder
# over a failed disk — a plain mountpoint check passes on that and would
# put a share on a dead disk). Absolute paths only: dirname of a relative
# path bottoms out at "." and never reaches "/".
# under /mnt only: tmpfs mountpoints (/run, /dev/shm) and the boot stick's
# /cfg pass a bare "is it on a mountpoint" walk, and a share there vanishes
# at reboot (or fills the tiny config partition) — disks live under /mnt.
_share_path_ok() {
	case "$1" in /mnt/?*) ;; *) return 1 ;; esac
	[ "$(_path_on_disk "$1")" = ok ]
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
	# 'force user' counts as granted: deleting a share's force-user account
	# bricks the share for EVERYONE at connect time (testparm cannot catch
	# it — it does not validate accounts), so removal must clear the same
	# double-opt-in as a listed user. 'nobody' (guest shares) is exempt.
	testparm -s "$SMB_CONF" 2>/dev/null \
		| sed -n 's/^[[:space:]]*valid users *= *//p; s/^[[:space:]]*read list *= *//p; s/^[[:space:]]*force user *= *//p' \
		| tr ',' '\n' | tr -d '\t ' | grep -v '^@' | grep -vx nobody | grep . | sort -u
}
# argument-shape guard for user names arriving at allow/revoke/user …:
# a leading dash would reach grep/smbpasswd/deluser in flag position.
# Wider than 'user add' creates (uppercase and dots allowed): pre-existing
# samba accounts made by hand must stay manageable through the command.
_share_user_arg_ok() {
	case "$1" in ''|*[!A-Za-z0-9._-]*|[._-]*) return 1 ;; *) return 0 ;; esac
}
_share_samba_users() {
	pdbedit -L 2>/dev/null | cut -d: -f1 | sort -u
}

cmd_share() {
	local sub name path u ro bak owner ans mode users lost created
	sub=${1:-list}
	case "$sub" in
	list)
		hdr "shares (managed + hand-written; effective values via testparm)"
		# ONE testparm fork and ONE managed-name listing serve the whole branch
		users=$(testparm -s "$SMB_CONF" 2>/dev/null)
		lost=$(_share_names)
		printf '%s\n' "$users" | awk '
			/^\[/ { sec = substr($0, 2, length($0) - 2); if (sec != "global") print "SHARE\t" sec; next }
			/^[[:space:]]*path *=/       { sub(/^[^=]*= */, ""); print "path\t" $0 }
			/^[[:space:]]*valid users *=/{ sub(/^[^=]*= */, ""); print "users\t" $0 }
			/^[[:space:]]*read list *=/  { sub(/^[^=]*= */, ""); print "ro\t" $0 }
			/^[[:space:]]*read only *=/  { sub(/^[^=]*= */, ""); print "readonly\t" $0 }
			/^[[:space:]]*guest ok *=/   { sub(/^[^=]*= */, ""); print "guest\t" $0 }
		' | awk -F'\t' -v managed="$(printf '%s\n' "$lost" | tr '\n' '\t')" '
			$1 == "SHARE" {
				if (cur != "") emit()
				cur = $2; p = us = ro = ""; ronly = "Yes"; guest = "No"
				next
			}
			$1 == "path"     { p = $2 }
			$1 == "users"    { us = $2 }
			$1 == "ro"       { ro = $2 }
			$1 == "readonly" { ronly = $2 }
			$1 == "guest"    { guest = $2 }
			END { if (cur != "") emit() }
			function emit(   tag, acc) {
				# tab-delimited probe: managed names cannot hold tabs, so a
				# hand-written section named "media backup" cannot match the
				# two managed names "media" + "backup" joined together
				tag = index("\t" managed "\t", "\t" cur "\t") ? "managed" : "manual "
				if (tolower(guest) == "yes") acc = "guest"
				else acc = (us == "" ? "(no valid users — everyone with a samba login)" : us)
				printf "  [%s] %-16s %-30s %s%s%s\n", tag, cur, p, acc, \
					(tolower(ronly) == "yes" ? "  [read-only]" : ""), \
					(ro != "" ? "  [ro: " ro "]" : "")
			}'
		[ -n "$lost" ] || [ -n "$(printf '%s\n' "$users" | grep -v '^\[global\]' | grep '^\[')" ] \
			|| hint "no shares yet — create one: nas share add <name> <path>"
		;;
	add)
		name=${2:-}; path=${3:-}
		[ -n "$name" ] && [ -n "$path" ] || { usage "nas share add <name> <path>"; return 1; }
		# lowercase only: samba resolves section names case-INsensitively, so
		# 'Global' would merge into [global] and 'Media' would shadow 'media'
		case "$name" in
			*[!a-z0-9_-]*|[_-]*) bad "share names are lowercase letters, digits, _ and - (first character a letter or digit)"; return 1 ;;
			global|homes|printers) bad "'$name' is a reserved samba section name"; return 1 ;;
		esac
		_share_names | grep -qxF "$name" && { bad "share [$name] already exists (see: nas share)"; return 1; }
		# -i: a hand-written [Media] and a managed [media] are the SAME share
		# to a connecting client — samba would serve one definition at random
		testparm -s "$SMB_CONF" 2>/dev/null | grep -qixF "[$name]" \
			&& { bad "a hand-written share [$name] exists in smb.conf — pick another name"; return 1; }
		_share_path_ok "$path" || {
			bad "$path is not on a mounted disk under /mnt — a share elsewhere vanishes at reboot"
			hint "mount the disk first (nas disks shows a paste-ready fstab line)"; return 1; }
		# a PRE-broken smb.conf must fail here, with the right suspect — not
		# after our edit, where the gate would blame the new share
		testparm -s "$SMB_CONF" >/dev/null 2>&1 \
			|| { bad "smb.conf is already invalid (testparm rejects it) — fix that first: testparm -s"; return 1; }
		mode=""
		if [ ! -d "$path" ]; then
			# EOF (an underfilled script pipe) must mean NO — creating the
			# directory may never ride on a missing answer
			printf '%s does not exist. Create it? [Y/n]: ' "$path"
			IFS= read -r ans || { echo "Cancelled (no answer)."; return 1; }
			case "$ans" in [nN]*) echo "Cancelled."; return 1 ;; esac
			mkdir -p "$path" || { bad "cannot create $path"; return 1; }
			mode=created   # only a dir WE made is re-owned below
		fi
		created=$mode
		# access: guest, an existing samba user, or a new one — asked, not
		# flagged. The prompts read stdin, so scripts can pipe the answers
		# (the same pattern the setup wizard uses).
		owner=""; mode=rw
		printf 'Access for [%s]:  [1] a user (recommended)  [2] guest (no password, read-only): ' "$name"
		IFS= read -r ans || ans=""
		case "$ans" in 2|g|guest) ans=2 ;; esac
		if [ "$ans" = 2 ]; then
			owner=@guest
		else
			users=$(_share_samba_users)
			printf 'Samba users:%s\n' "$(printf '%s' "$users" | tr '\n' ' ' | sed 's/^/ /;s/ $//')"
			printf 'User name (existing, or a new one to create): '; IFS= read -r u || u=""
			[ -n "$u" ] || { bad "a user is required"; return 1; }
			if ! printf '%s\n' "$users" | grep -qxF "$u"; then
				cmd_share user add "$u" || return 1
			fi
			owner=$u
			printf 'Access for %s:  [1] read-write  [2] read-only: ' "$u"; IFS= read -r ans || ans=""
			[ "$ans" = 2 ] && mode=ro
		fi
		_share_ensure_include || return 1
		[ -f "$SHARES_CONF" ] || : > "$SHARES_CONF"
		bak=$(_share_begin) || { bad "cannot take the pre-edit backup (RAM root full?)"; return 1; }
		{
			printf '\n[%s]\n' "$name"
			printf '   ; managed by nas share — edit via the command, not by hand\n'
			printf '   path = %s\n' "$path"
			if [ "$owner" = @guest ]; then
				printf '   guest ok = yes\n   read only = yes\n   force user = nobody\n'
			else
				printf '   valid users = %s\n' "$owner"
				[ "$mode" = ro ] && printf '   read list = %s\n' "$owner"
				printf '   read only = no\n   force user = %s\n' "$owner"
			fi
			printf '   browseable = yes\n'
		} >> "$SHARES_CONF" || { _share_abort "$bak"; return 1; }
		_share_gate "$bak" || return 1
		# a dir this command just created belongs to the share's owner so
		# writes work; a PRE-EXISTING dir keeps its ownership untouched
		[ "$owner" != @guest ] && [ "$created" = created ] && chown "$owner" "$path" 2>/dev/null
		_share_reload
		ok "share [$name] -> $path ($([ "$owner" = @guest ] && echo 'guest, read-only' || echo "$owner, $mode"))"
		hint "reach it at \\\\$(hostname)\\$name  (or smb://$(hostname).local/$name)"
		_share_fw_hint
		_share_unsaved
		;;
	remove|delete)
		name=${2:-}
		[ -n "$name" ] || { usage "nas share remove <name>"; return 1; }
		_share_names | grep -qxF "$name" || {
			if testparm -s "$SMB_CONF" 2>/dev/null | grep -qixF "[$name]"; then
				bad "[$name] is a hand-written share in smb.conf — remove it there (this command never edits your smb.conf shares)"
			else
				bad "no managed share [$name] (see: nas share)"
			fi
			return 1; }
		users=$(_share_get "$name" "valid users" | tr ',' '\n' | tr -d ' ' | grep .)
		path=$(_share_get "$name" "path")
		bak=$(_share_begin) || { bad "cannot take the pre-edit backup (RAM root full?)"; return 1; }
		_share_drop_section "$name" || { rm -f "$bak"; bad "rewrite failed — [$name] is unchanged"; return 1; }
		_share_gate "$bak" || return 1
		_share_reload
		ok "share [$name] removed — the directory ($path) and its files are untouched"
		# a user this removal orphaned (on no other share) is offered up too
		lost=$(_share_all_granted)
		for u in $users; do
			printf '%s\n' "$lost" | grep -qxF "$u" && continue
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
		_share_user_arg_ok "$u" || { bad "invalid user name '$u'"; return 1; }
		case "$ro" in ''|--ro) ;; *) usage "nas share allow <name> <user> [--ro]"; return 1 ;; esac
		_share_names | grep -qxF "$name" || { bad "no managed share [$name] (hand-written shares stay hand-edited)"; return 1; }
		_share_samba_users | grep -qxF "$u" || { bad "no samba user '$u' — create one: nas share user add $u"; return 1; }
		[ "$(_share_get "$name" "guest ok")" = yes ] && { bad "[$name] is a guest share — user grants do not apply"; return 1; }
		bak=$(_share_begin) || { bad "cannot take the pre-edit backup (RAM root full?)"; return 1; }
		users=$(_share_get "$name" "valid users")
		printf '%s' ", $users," | grep -qF ", $u," \
			|| _share_set "$name" "valid users" "${users:+$users, }$u" || { _share_abort "$bak"; return 1; }
		if [ "$ro" = "--ro" ]; then
			users=$(_share_get "$name" "read list")
			printf '%s' ", $users," | grep -qF ", $u," \
				|| _share_set "$name" "read list" "${users:+$users, }$u" || { _share_abort "$bak"; return 1; }
		fi
		_share_gate "$bak" || return 1
		_share_reload
		ok "$u -> [$name]${ro:+ (read-only)}"
		_share_unsaved
		;;
	revoke)
		name=${2:-}; u=${3:-}
		[ -n "$name" ] && [ -n "$u" ] || { usage "nas share revoke <name> <user>"; return 1; }
		_share_user_arg_ok "$u" || { bad "invalid user name '$u'"; return 1; }
		_share_names | grep -qxF "$name" || { bad "no managed share [$name]"; return 1; }
		# a user who is NOT on the share is a no-op, reported as one — a
		# false "revoked" (and a scary empty-list warning) for a state this
		# command did not change helps nobody
		if ! { _share_get "$name" "valid users"; _share_get "$name" "read list"; } \
			| tr ',' '\n' | tr -d ' ' | grep -qxF "$u"; then
			hint "'$u' is not on [$name] — nothing to revoke"; return 0
		fi
		bak=$(_share_begin) || { bad "cannot take the pre-edit backup (RAM root full?)"; return 1; }
		# edit only the list(s) the user is actually on — dropping an absent
		# key must not fire the empty-list warning for an unchanged share
		for mode in "valid users" "read list"; do
			users=$(_share_get "$name" "$mode")
			printf '%s\n' "$users" | tr ',' '\n' | tr -d ' ' | grep -qxF "$u" || continue
			users=$(printf '%s\n' "$users" | tr ',' '\n' | tr -d ' ' | grep -vxF "$u" | paste -sd, - | sed 's/,/, /g')
			if [ -n "$users" ]; then _share_set "$name" "$mode" "$users" || { _share_abort "$bak"; return 1; }
			else
				_share_drop_key "$name" "$mode" || { _share_abort "$bak"; return 1; }
				[ "$mode" = "valid users" ] \
					&& warn "[$name] now has NO user list — every samba login can reach it; remove the share or allow a user"
			fi
		done
		_share_gate "$bak" || return 1
		_share_reload
		ok "$u revoked from [$name]"
		[ "$(_share_get "$name" "force user")" = "$u" ] 			&& warn "$u is still [$name]'s 'force user' (writes act as $u) — deleting the account would break the share"
		_share_unsaved
		;;
	user|users)
		case "${2:-list}" in
		list)
			hdr "samba users"
			lost=$(_share_all_granted)
			users=$(_share_samba_users)
			printf '%s\n' "$users" | while IFS= read -r u; do
				[ -n "$u" ] || continue
				if printf '%s\n' "$lost" | grep -qxF "$u"; then
					printf '  %-20s\n' "$u"
				else
					printf '  %-20s (on no share)\n' "$u"
				fi
			done
			[ -n "$users" ] || hint "no samba users yet — nas share user add <name>"
			;;
		add)
			u=${3:-}
			[ -n "$u" ] || { usage "nas share user add <user>"; return 1; }
			case "$u" in *[!a-z0-9_-]*|[_-]*|'') bad "user names are lowercase letters, digits, _ and - (first character a letter or digit)"; return 1 ;; esac
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
			_share_user_arg_ok "$u" || { bad "invalid user name '$u'"; return 1; }
			_share_samba_users | grep -qxF "$u" || { bad "no samba user '$u'"; return 1; }
			_share_smbpasswd "$u" && ok "password changed for $u" && _share_unsaved
			;;
		remove)
			u=${3:-}
			[ -n "$u" ] || { usage "nas share user remove <user>"; return 1; }
			_share_user_arg_ok "$u" || { bad "invalid user name '$u'"; return 1; }
			_share_samba_users | grep -qxF "$u" || { bad "no samba user '$u'"; return 1; }
			if _share_all_granted | grep -qxF "$u"; then
				warn "$u is still granted on a share — revoke first, or confirm to remove anyway"
				printf "Type the user name to confirm removal: "
				IFS= read -r ans || ans=""
				[ "$ans" = "$u" ] || { echo "Cancelled."; return 1; }
			fi
			smbpasswd -x "$u" >/dev/null 2>&1 || warn "smbpasswd -x $u failed (already gone?)"
			# only delete Linux accounts of the SMB-only shape 'user add'
			# creates. 'user add' also enrolls pre-existing login accounts —
			# deleting one of those here would kill its SSH/doas access, far
			# beyond "delete a samba user".
			case "$(awk -F: -v n="$u" '$1==n{print $NF}' /etc/passwd)" in
				*/nologin|*/false)
					deluser "$u" >/dev/null 2>&1 || warn "deluser $u failed"
					ok "samba user $u removed (files owned by the user are untouched)" ;;
				'') ok "samba credential removed ($u had no Linux account)" ;;
				*)  ok "samba credential removed — the Linux account $u is KEPT (it has a login shell)" ;;
			esac
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
