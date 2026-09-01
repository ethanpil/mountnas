# shellcheck shell=sh
# nas mount
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas mount — fstab + mount for an ALREADY-FORMATTED partition, permanently.
# NEVER formats anything: 'nas disk init' is the one destructive command,
# and it chains into _mount_flow below after mkfs. Append-only against
# fstab — the file stays the user-owned source of truth; this is a typing
# aid with guardrails (never the boot USB, never a duplicate entry).
# One-time mounts stay plain mount(8). Design record: SPEC-roadmap-4.md §1.

# resolve a user-supplied disk identifier to /dev/<part>:
# a device path, a filesystem UUID, a LABEL, or a disk SERIAL (whole-disk
# serial resolves to its single data partition). Empty output = no match.
_mount_resolve() {
	local id dev
	id=$1
	case "$id" in
		/dev/*) [ -b "$id" ] && printf '%s' "$id"; return ;;
	esac
	dev=$(findfs "UUID=$id" 2>/dev/null) || dev=""
	[ -n "$dev" ] || dev=$(findfs "LABEL=$id" 2>/dev/null) || dev=""
	if [ -z "$dev" ]; then
		# serial -> the disk -> its ONE partition. A multi-partition disk is
		# deliberately NOT resolved by serial (silently picking p1 could
		# fstab a 100 MB EFI partition) — address those by /dev path.
		dev=$(lsblk -Jo NAME,TYPE,SERIAL 2>/dev/null | jq -r --arg s "$id" '
			.blockdevices[] | select(.type=="disk")
			| select((.serial // "") == $s)
			| select(((.children // []) | map(select(.type=="part")) | length) == 1)
			| .children[] | select(.type=="part") | "/dev/" + .name' | head -n1)
	fi
	printf '%s' "$dev"
}
# partitions eligible for 'nas mount': carry a filesystem, not the boot USB,
# not BOOT/MNASCFG, not already in an active fstab entry. TSV: dev fstype label uuid size
_mount_candidates() {
	local usb
	usb=$(_boot_usb_disk)
	lsblk -Jo NAME,TYPE,FSTYPE,LABEL,UUID,SIZE 2>/dev/null | jq -r '
		def s(f): (f // "-") | tostring;
		.blockdevices[] | select(.type=="disk")
		| select(.name | test("^(fd|sr|loop|ram|zram)") | not) as $d | $d.children[]?
		| select(.type=="part") | select(.uuid and .fstype)
		| [$d.name, .name, .fstype, s(.label), .uuid, s(.size)] | @tsv' \
	| while IFS="$(printf '\t')" read -r pk name fstype label uuid size; do
		[ "$pk" = "$usb" ] && continue
		case "$label" in BOOT|MNASCFG) continue ;; esac
		awk '$1!~/^#/' /etc/fstab 2>/dev/null | grep -qF "$uuid" && continue
		printf '/dev/%s\t%s\t%s\t%s\t%s\n' "$name" "$fstype" "$label" "$uuid" "$size"
	done
}
# the shared add-to-fstab flow. $1 = /dev/<part>. Asks the role, appends the
# fstab line, mounts via the supervisor, then offers 'nas snapraid add' for
# array roles. Prompts read stdin (pipeable, the wizard pattern).
# $2 (optional) = a role preset from 'nas disk init': the chain must not
# ask the role AGAIN with different numbering (init: 1=nasdata,2=data,3=
# parity; here: 1=data,2=parity,3=nasdata — a reflexive same-answer would
# silently flip a data disk into parity).
_mount_flow() {
	local dev uuid fstype label mp role ans
	dev=$1
	# ONE blkid fork; export format is KEY=value per line
	uuid=$(blkid -o export "$dev" 2>/dev/null)
	fstype=$(printf '%s\n' "$uuid" | sed -n 's/^TYPE=//p')
	label=$(printf '%s\n' "$uuid" | sed -n 's/^LABEL=//p')
	uuid=$(printf '%s\n' "$uuid" | sed -n 's/^UUID=//p')
	[ -n "$uuid" ] && [ -n "$fstype" ] || { bad "$dev has no readable filesystem"; return 1; }
	# guardrails, same rules 'nas status' enforces after the fact. The
	# duplicate check matches UUID=, LABEL= AND the /dev path — fstab
	# entries legitimately use any of the three.
	[ "$(lsblk -no pkname "$dev" 2>/dev/null | head -n1)" = "$(_boot_usb_disk)" ] \
		&& { bad "$dev is on the BOOT USB — never a data disk"; return 1; }
	if awk '$1!~/^#/ {print $1}' /etc/fstab 2>/dev/null \
		| grep -qxF -e "UUID=$uuid" ${label:+-e "LABEL=$label"} -e "$dev"; then
		bad "$dev is already in fstab (by UUID, label or device path)"; return 1
	fi
	# already hand-mounted somewhere? say so before asking the role
	mp=$(awk -v d="$dev" '$1==d {print $2; exit}' /proc/mounts)
	[ -n "$mp" ] && hint "$dev is currently mounted at $mp (a manual mount)"
	role=${2:-}
	if [ -z "$role" ]; then
		printf 'Add %s (%s%s) as:\n' "$dev" "$fstype" "${label:+, label $label}"
		printf '  [1] data disk    (next free /mnt/diskN)\n'
		printf '  [2] parity disk  (next free /mnt/parityN)\n'
		printf '  [3] nasdata      (the system disk — Docker, appdata, backups)\n'
		printf '  [4] custom path\n'
		printf ': '; IFS= read -r role || role=""
	fi
	case "$role" in
		1) mp=$(_next_free_mp disk) ;;
		2) mp=$(_next_free_mp parity) ;;
		3) _fstab_has_mp /mnt/nasdata \
			&& { bad "fstab already maps /mnt/nasdata — remove that line first if you mean to replace it"; return 1; }
		   mp=/mnt/nasdata ;;
		4) printf 'Mountpoint (under /mnt): '; IFS= read -r mp || mp=""
		   mp=${mp%/}
		   case "$mp" in /mnt/?*) ;; *) bad "the mountpoint must live under /mnt"; return 1 ;; esac
		   # spaces make a 7-field fstab line the supervisor misparses
		   case "$mp" in *[!A-Za-z0-9/_.-]*) bad "the mountpoint may not contain spaces or shell metacharacters"; return 1 ;; esac
		   _fstab_has_mp "$mp" && { bad "fstab already maps $mp"; return 1; } ;;
		*) echo "Cancelled."; return 1 ;;
	esac
	printf 'UUID=%s  %s  %s  rw,noatime,nofail  0 2\n' "$uuid" "$mp" "$fstype" >> /etc/fstab \
		|| { bad "cannot append to /etc/fstab"; return 1; }
	ok "fstab: UUID=$uuid  $mp  $fstype  rw,noatime,nofail"
	# the supervisor mounts fstab data disks and creates the mountpoint
	rc-service mountnas restart >/dev/null 2>&1 || true
	# _blocked: a FAILED mount gets the supervisor's read-only placeholder,
	# which a bare mountpoint check reports as success
	if mountpoint -q "$mp" 2>/dev/null && ! _blocked "$mp"; then
		ok "mounted at $mp (via the supervisor)"
	else
		warn "NOT mounted (or only the failure placeholder is) — check: nas status"
		hint "the SnapRAID offer is skipped until the disk really mounts"
		role=none
	fi
	_ops_log mount "$dev -> $mp"
	# complete the chain for array roles: the conf edit happens only through
	# the one append-only path, and only on an explicit yes — EOF on stdin
	# (an underfilled script pipe) must mean NO, never yes
	case "$role" in 1|2)
		printf 'Add it to the SnapRAID array now? [Y/n]: '
		if IFS= read -r ans; then
			case "$ans" in n|N) hint "later: nas snapraid add $mp$([ "$role" = 2 ] && echo ' --parity')" ;;
				*) if [ "$role" = 2 ]; then cmd_snapraid add "$mp" --parity; else cmd_snapraid add "$mp"; fi ;;
			esac
		else
			hint "no answer (EOF) — later: nas snapraid add $mp$([ "$role" = 2 ] && echo ' --parity')"
		fi ;;
	esac
	if lbu status 2>/dev/null | grep -q 'etc/fstab'; then
		warn "fstab change NOT saved — gone after a reboot unless you run: nas commit"
	fi
	return 0
}

cmd_mount() {
	local dev sel line i
	if [ -n "${1:-}" ]; then
		dev=$(_mount_resolve "$1")
		[ -n "$dev" ] || { bad "nothing matches '$1' (a /dev path, UUID, label or disk serial)"; hint "candidates: nas mount"; return 1; }
		_mount_flow "$dev"
		return
	fi
	hdr "partitions not in fstab (formatted, non-boot)"
	line=$(_mount_candidates)
	if [ -z "$line" ]; then
		hint "none — every filesystem is in fstab already. A BLANK disk is formatted with: nas disk init"
		return 0
	fi
	i=0
	printf '%s\n' "$line" | while IFS="$(printf '\t')" read -r d f l u s; do
		i=$((i + 1))
		printf '  [%d] %-12s %-6s %-12s %-8s %s\n' "$i" "$d" "$f" "${l:--}" "$s" "$u"
	done
	printf 'Which one? [1-%s]: ' "$(printf '%s\n' "$line" | grep -c .)"
	IFS= read -r sel || sel=""
	case "$sel" in ''|*[!0-9]*) echo "Cancelled."; return 1 ;; esac
	dev=$(printf '%s\n' "$line" | awk -v n="$sel" 'NR==n{print $1}')
	[ -n "$dev" ] || { bad "no candidate $sel"; return 1; }
	_mount_flow "$dev"
}

# help page for 'nas mount --help' / 'nas help mount'
help_mount() {
	cat <<EOF
nas mount [disk]
  Add an ALREADY-FORMATTED partition to /etc/fstab and mount it — the
  permanent version of mount(8) (one-time mounts: use plain 'mount').
  [disk] is a /dev path, filesystem UUID, label, or disk serial; with no
  argument, the eligible partitions are listed to pick from.
  Guardrails: never the boot USB, never a duplicate fstab entry; the
  line is APPENDED — your existing fstab lines are never edited.
  Data/parity roles end by offering 'nas snapraid add'. This command
  never formats anything; a BLANK disk is prepared with 'nas disk init'.
  IMPORTANT: the fstab line lives in RAM until 'nas commit'.
EOF
}
