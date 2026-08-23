# shellcheck shell=sh
# nas disks [--json]
# Sourced by /usr/sbin/nas (never run directly). Shared helpers: lib.sh.

# nas disks — one header row per physical disk (hardware identity: vendor,
# model, serial, firmware, bus, HDD/SSD, temperature) with its partitions
# indented underneath (fstype, label, UUID, mountpoint, free space), plus a
# paste-ready fstab line for each unconfigured data partition. All identity
# fields come from lsblk/sysfs — no disk spin-up.
cmd_disks() {
	local usb TAB blank_pending blank_dev k f1 f2 f3 f4 f5 f6 f7 f8 tag bus dtp drow ctag pad id sn fw lbl minfo have_nd lines n mp phys
	usb=$(_boot_usb_disk)
	TAB=$(printf '\t')

	hdr "Detected disks"
	hint "* = MountNAS boot USB — do NOT add to fstab"
	# JSON + jq (not 'eval' of lsblk pairs): a filesystem label is arbitrary user
	# data — under eval a label like '$(...)' would run as root, and quotes or
	# spaces would garble parsing. jq emits TSV with '-' placeholders for empty
	# fields so the tab-separated read can't collapse columns either. A "D" row
	# per disk, then a "P" row per partition — including the disk itself when a
	# filesystem sits directly on it (no partition table).
	lsblk -Jo 'NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT,FSAVAIL,FSUSE%,VENDOR,MODEL,SERIAL,REV,TRAN,ROTA' 2>/dev/null \
	| jq -r '
		def s(f): (f // "-") | tostring | gsub("^\\s+|\\s+$"; "") | if . == "" then "-" else . end;
		def prow: [ "P", .name, s(.size), s(.fstype), s(.label), s(.uuid),
		            (.mountpoint // "-"), s(.fsavail), s(."fsuse%") ] | @tsv;
		.blockdevices[] | select(.type=="disk") | select(.name | test("^(fd|sr|loop|ram|zram)") | not) as $d |
		( [ "D", $d.name, s($d.size), s($d.tran),
		    (if $d.rota then "HDD" else "SSD" end),
		    s($d.vendor), s($d.model), s($d.serial), s($d.rev) ] | @tsv ),
		( $d | select(.fstype != null) | prow ),
		( $d.children[]? | select(.type=="part") | prow )' \
	| { blank_pending=0; blank_dev=""
	while IFS="$TAB" read -r k f1 f2 f3 f4 f5 f6 f7 f8; do
		case "$k" in
		D)
			# f1=name f2=size f3=tran f4=HDD/SSD f5=vendor f6=model f7=serial f8=rev
			# Two lines per disk under a dashed rule — everything stays inside
			# ~76 columns (the old single-line format overflowed serial consoles).
			if [ "$blank_pending" = 1 ]; then
				printf '     %s(blank — no filesystem; create one first, e.g. mkfs.ext4 -L data1 /dev/%s)%s\n' "$C_WA" "$blank_dev" "$C_NO"
			fi
			tag=""; [ "$f1" = "$usb" ] && tag="  *BOOT USB*"
			bus=""; [ "$f3" != "-" ] && bus="$f3 "
			dtp=$(_disk_temp "$f1")
			# width math on the UNCOLORED text; escapes would inflate ${#}
			drow="$f1  $f2  $bus$f4  temp:$dtp$tag"
			ctag="$tag"; [ -n "$tag" ] && ctag="  $C_FA*BOOT USB*$C_NO"
			pad=$((UI_W - 4 - ${#drow})); [ "$pad" -gt 0 ] || pad=2
			printf -- '\n-- %s %.*s\n' "$C_B$f1$C_NO  $f2  $bus$f4  temp:$dtp$ctag" "$pad" "$_RULE_DA"
			id=""
			[ "$f5" != "-" ] && id="$f5 "
			[ "$f6" != "-" ] && id="$id$f6"
			[ -n "$id" ] || id="(unknown model)"
			sn=""; [ "$f7" != "-" ] && sn="  SN:$f7"
			fw=""; [ "$f8" != "-" ] && fw="  fw:$f8"
			printf '     %s%s%s\n' "$id" "$sn" "$fw"
			blank_pending=1; blank_dev="$f1"
			;;
		P)
			# f1=name f2=size f3=fstype f4=label f5=uuid f6=mountpoint f7=avail f8=use%
			# Two lines per partition: identity/mount first, the 36-char UUID on
			# its own line beneath (the UUID is what forced 120+ columns before).
			blank_pending=0
			# minfo/tag are trailing %s fields (no width specs), so the color
			# escapes cannot skew the column alignment
			tag=""
			[ "$f4" = BOOT ] && tag="  $C_FA* (BOOT)$C_NO"
			[ "$f4" = MNASCFG ] && tag="  $C_FA* (cfg)$C_NO"
			lbl=""; [ "$f4" != "-" ] && lbl="  $f4"
			if [ "$f6" = "-" ]; then minfo="$C_D(not mounted)$C_NO"
			else
				minfo="$C_OK$f6$C_NO"
				[ "$f7" != "-" ] && minfo="$minfo  ($f7 free, $f8 used)"
			fi
			printf '     %-6s %6s  %-8s%s  -> %s%s\n' "$f1" "$f2" "$f3" "$lbl" "$minfo" "$tag"
			[ "$f5" != "-" ] && printf '            UUID=%s\n' "$f5"
			;;
		esac
	done
	if [ "$blank_pending" = 1 ]; then
		printf '     %s(blank — no filesystem; create one first, e.g. mkfs.ext4 -L data1 /dev/%s)%s\n' "$C_WA" "$blank_dev" "$C_NO"
	fi; }

	hdr "Configured in /etc/fstab"
	awk '$1!~/^#/ && $2 ~ /^(\/cfg|\/mnt\/)/ {printf "  %-14s %s\n",$2,$1}' /etc/fstab

	hdr "Paste-ready fstab line(s) for unconfigured data partitions"
	# Build in a subshell-captured var: the while loop below runs in a pipe subshell,
	# so a flag set inside it would not survive — check the captured output instead.
	# Suggested mountpoints: /mnt/nasdata first (only if not already in fstab),
	# then /mnt/disk1, /mnt/disk2, … — never the same mountpoint twice.
	# jq carries the parent disk name so partitions of the boot USB are skipped
	# reliably, plus the disk's vendor/model/serial: the line ends with a comment
	# identifying the PHYSICAL drive, so a stale fstab entry can be traced back
	# to the disk in hand long after mkfs changed its UUID.
	have_nd=$(awk '$1!~/^#/ && $2=="/mnt/nasdata"{f=1} END{print f+0}' /etc/fstab)
	lines=$(lsblk -Jo NAME,TYPE,FSTYPE,LABEL,UUID,VENDOR,MODEL,SERIAL 2>/dev/null \
	| jq -r '
		def s(f): (f // "-") | tostring | gsub("^\\s+|\\s+$"; "") | if . == "" then "-" else . end;
		.blockdevices[] | select(.type=="disk") | select(.name | test("^(fd|sr|loop|ram|zram)") | not) as $d | $d.children[]?
		| select(.type=="part") | select(.uuid and .fstype)
		| [$d.name, s($d.vendor), s($d.model), s($d.serial),
		   .name, .fstype, s(.label), .uuid] | @tsv' \
	| { n=1; while IFS="$TAB" read -r PK VEND MOD SER NAME FSTYPE LABEL UUID; do
		case "$LABEL" in BOOT|MNASCFG) continue ;; esac
		[ "$PK" = "$usb" ] && continue
		# already referenced in an ACTIVE fstab entry (by UUID)? Commented-out
		# lines don't count: a disk the user disabled by commenting its entry
		# must get its paste-ready line back.
		awk '$1!~/^#/' /etc/fstab 2>/dev/null | grep -qF "$UUID" && continue
		if [ "$have_nd" = 0 ]; then mp=/mnt/nasdata; have_nd=1
		else
			while awk -v m="/mnt/disk$n" '$1!~/^#/ && $2==m{f=1} END{exit !f}' /etc/fstab; do n=$((n+1)); done
			mp="/mnt/disk$n"; n=$((n+1))
		fi
		phys=""
		[ "$VEND" != "-" ] && phys="$VEND "
		[ "$MOD" != "-" ] && phys="$phys$MOD "
		[ "$SER" != "-" ] && phys="${phys}SN:$SER "
		printf "  UUID=%s  %-13s %s  rw,noatime,nofail  0 2   # %s(edit mountpoint)\n" "$UUID" "$mp" "$FSTYPE" "$phys"
	done; })
	[ -n "$lines" ] && printf '%s\n' "$lines" \
		|| echo "  (none — every filesystem is already in fstab, or blank/unformatted)"
	hint "Tip: the system disk uses /mnt/nasdata; extra data/parity disks use any path"
	hint "     you like (the /mnt/disk1, /mnt/parity1 names are just a convention)."
}

# nas disks --json — the same inventory, machine-readable. Sizes are BYTES
# (lsblk -b); temp is the standby-safe reading ("standby" for sleeping drives,
# null when no sensor exists); in_fstab marks partitions already referenced by
# UUID in /etc/fstab.
cmd_disks_json() {
	local usb lj temps d t fuuids flabels fdevs
	usb=$(_boot_usb_disk)
	# one lsblk dump feeds both the disk-name list (for temps) and the output
	lj=$(lsblk -Jbo 'NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT,FSAVAIL,VENDOR,MODEL,SERIAL,REV,TRAN,ROTA' 2>/dev/null)
	temps=$(printf '%s' "$lj" | jq -r '.blockdevices[]? | select(.type=="disk") | select(.name | test("^(fd|sr|loop|ram|zram)") | not) | .name' | while read -r d; do
		t=$(_disk_temp "$d"); [ "$t" = "-" ] && continue
		printf '{"name":"%s","temp":"%s"}\n' "$d" "$t"
	done | jq -s 'map({(.name): .temp}) | add // {}')
	# fstab entries can name a filesystem by UUID=, LABEL=, or a /dev/ path —
	# all three are valid and documented. Collect each kind and match against
	# the partition's uuid / label / name, so a LABEL=-based entry (common, and
	# what 'nas disks' pastes) no longer reads in_fstab:false.
	fuuids=$(awk '$1!~/^#/ && $1~/^UUID=/{sub("UUID=","",$1); print $1}' /etc/fstab 2>/dev/null | jq -R . | jq -s .)
	flabels=$(awk '$1!~/^#/ && $1~/^LABEL=/{sub("LABEL=","",$1); print $1}' /etc/fstab 2>/dev/null | jq -R . | jq -s .)
	fdevs=$(awk '$1!~/^#/ && $1~/^\/dev\//{sub("/dev/","",$1); print $1}' /etc/fstab 2>/dev/null | jq -R . | jq -s .)
	printf '%s' "$lj" \
	| jq --arg usb "$usb" --argjson temps "$temps" \
	     --argjson fuuids "$fuuids" --argjson flabels "$flabels" --argjson fdevs "$fdevs" '
		# bind the fields BEFORE piping into index(): inside index(f) the filter f
		# is evaluated against the piped-in array, so a bare .uuid there indexed
		# the ARRAY and crashed ("Cannot index array with string uuid")
		def part: (.uuid // "") as $u | (.label // "") as $l | (.name // "") as $n |
		          { name, size, fstype, label, uuid, mountpoint, fsavail,
		            in_fstab: ( ($u != "" and (($fuuids  | index($u)) != null))
		                     or ($l != "" and (($flabels | index($l)) != null))
		                     or ($n != "" and (($fdevs   | index($n)) != null)) ) };
		{ boot_usb: (if ($usb | length) > 0 then $usb else null end),
		  disks: [ .blockdevices[] | select(.type=="disk") | select(.name | test("^(fd|sr|loop|ram|zram)") | not) | {
			name, size,
			bus: .tran, rotational: .rota,
			vendor, model, serial, firmware: .rev,
			temp: ($temps[.name] // null),
			boot_usb: (.name == $usb),
			partitions: ( [ .children[]? | select(.type=="part") | part ]
			              + (if .fstype != null then [ part ] else [] end) )
		  } ] }'
}

# help page for 'nas disks --help' / 'nas help disks'
help_disks() {
	cat <<EOF
nas disks [--json]
  Every disk with identity (model/serial/bus/temp), partitions (fstype,
  label, UUID, mountpoint, free space), fstab state, and a paste-ready
  fstab line per unconfigured partition. Never wakes sleeping disks.
  --json   same inventory, machine-readable (byte sizes)
EOF
}
