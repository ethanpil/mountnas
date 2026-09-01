#!/bin/sh
# nas mount + nas disk init — the block-device layer is stubbed (lsblk,
# blkid, findfs, parted, mkfs.*, wipefs); the gates, fstab surgery, role
# mapping and the init->mount->snapraid chain are real.
. "$(dirname "$0")/harness.sh"

CALLS=/tmp/storage-calls
stub lbu ':'
stub rc-service 'exit 0'
stub partprobe ':'
stub mountpoint 'case "$2" in /not-mounted*) exit 1 ;; *) exit 0 ;; esac'
# blkid values come from per-device files: /tmp/blk.<base>.<TAG>
stub blkid 'dev=""; tag=""; exp=0
while [ $# -gt 0 ]; do case "$1" in
	-s) tag=$2; shift 2 ;;
	-o) [ "$2" = export ] && exp=1; shift 2 ;;
	*) dev=$1; shift ;; esac; done
b=$(basename "$dev")
if [ "$exp" = 1 ]; then
	for k in UUID TYPE LABEL; do
		[ -f "/tmp/blk.$b.$k" ] && printf "%s=%s\n" "$k" "$(cat /tmp/blk.$b.$k)"
	done
else
	cat "/tmp/blk.$b.$tag" 2>/dev/null
fi'
stub findfs 'case "$1" in
	LABEL=BOOT) echo /dev/sda1 ;;
	UUID=cafe-1234) echo /dev/sdb1 ;;
	LABEL=oldmedia) echo /dev/sdb1 ;;
	*) exit 1 ;;
esac'
# lsblk answers by argument shape; JSON comes from swappable files
stub lsblk 'case "$*" in
	*pkname*/dev/sda*) echo sda ;;          # boot USB partitions
	*pkname*/dev/sdb1*) echo sdb ;;
	*pkname*/dev/sdc1*) echo sdc ;;         # ORDER: sdc1 before the sdc glob
	*pkname*/dev/sdc*) echo "" ;;           # sdc = whole disk (no parent)
	*-Jbo*) cat /tmp/lsblk-blank.json 2>/dev/null || echo "{\"blockdevices\":[]}" ;;
	*-Jo*NAME,TYPE,SERIAL*) cat /tmp/lsblk-serial.json 2>/dev/null || echo "{\"blockdevices\":[]}" ;;
	*-Jo*) cat /tmp/lsblk-cand.json 2>/dev/null || echo "{\"blockdevices\":[]}" ;;
	*-dno*serial*) echo SERIAL9876 ;;
	*-dno*model*) echo "TestDisk 4TB" ;;
	*-dbno*size*) echo 4000000000000 ;;
	*-rno*name*/dev/sdc*) printf "sdc\nsdc1\n" ;;
	*-no*name*/dev/sdc*) echo sdc ;;
	*-no*fstype*/dev/sdc*) echo "" ;;
	*) echo "" ;;
esac'
stub wipefs 'echo "$*" >> /tmp/storage-calls; cat /tmp/wipefs-out 2>/dev/null'
stub parted 'echo "parted $*" >> /tmp/storage-calls'
stub mkfs.ext4 'echo "mkfs.ext4 $*" >> /tmp/storage-calls'
stub mkfs.xfs 'echo "mkfs.xfs $*" >> /tmp/storage-calls'

seed() {
	# the chroot's private /dev lacks disk nodes; _mount_resolve checks -b
	for _n in sda1:1 sdb1:2 sdc:3 sdc1:4; do
		[ -b "/dev/${_n%%:*}" ] || mknod "/dev/${_n%%:*}" b 7 "${_n##*:}" 2>/dev/null
	done
	printf 'LABEL=MNASCFG  /cfg  ext4  rw,noatime,nofail  0 0\n' > /etc/fstab
	printf 'UUID=nd-1  /mnt/nasdata  ext4  rw,noatime,nofail  0 2\n' >> /etc/fstab
	: > /etc/snapraid.conf
	rm -f "$CALLS" /tmp/wipefs-out /tmp/lsblk-blank.json
	# sdb1: a formatted data partition (candidate)
	echo cafe-1234 > /tmp/blk.sdb1.UUID
	echo ext4 > /tmp/blk.sdb1.TYPE
	echo oldmedia > /tmp/blk.sdb1.LABEL
	# sdc1: the partition init creates
	echo new-5678 > /tmp/blk.sdc1.UUID
	echo ext4 > /tmp/blk.sdc1.TYPE
	printf '{"blockdevices":[{"name":"sdb","type":"disk","serial":"WD1122","children":[{"name":"sdb1","type":"part"}]}]}\n' > /tmp/lsblk-serial.json
}

t "mount: resolves a device by UUID, label and serial to the same partition"
seed
for id in cafe-1234 oldmedia WD1122; do
	OUT=$(printf '1\nn\n' | /usr/sbin/nas mount "$id" 2>&1); RC=$?
	assert_rc 0 "resolve '$id'"
	assert_match 'fstab: UUID=cafe-1234  /mnt/disk1  ext4' "$OUT"
	seed
done

t "mount: appends exactly one line and never edits existing ones"
seed
before=$(cat /etc/fstab)
OUT=$(printf '1\nn\n' | /usr/sbin/nas mount /dev/sdb1 2>&1); RC=$?
assert_rc 0
assert_eq "$before" "$(head -n 2 /etc/fstab)" "existing lines byte-identical"
assert_eq 3 "$(grep -c . /etc/fstab)" "exactly one appended line"

t "mount: boot USB and duplicate entries are refused"
seed
echo boot-uuid > /tmp/blk.sda1.UUID; echo vfat > /tmp/blk.sda1.TYPE
run_nas mount /dev/sda1
assert_rc 1
assert_match 'BOOT USB' "$OUT"
printf 'UUID=cafe-1234  /mnt/old  ext4  rw,noatime,nofail  0 2\n' >> /etc/fstab
run_nas mount /dev/sdb1
assert_rc 1
assert_match 'already in fstab' "$OUT"

t "mount: parity role numbers parityN and offers snapraid add"
seed
mkdir -p /mnt/parity1
OUT=$(printf '2\ny\n' | /usr/sbin/nas mount /dev/sdb1 2>&1); RC=$?
assert_rc 0
assert_match '/mnt/parity1' "$OUT"
assert_match '^parity /mnt/parity1/snapraid.parity$' "$(cat /etc/snapraid.conf)"

t "mount: nasdata role refused when fstab already maps it"
seed
OUT=$(printf '3\n' | /usr/sbin/nas mount /dev/sdb1 2>&1); RC=$?
assert_rc 1
assert_match 'already maps /mnt/nasdata' "$OUT"

t "mount: custom path must live under /mnt"
seed
OUT=$(printf '4\n/srv/x\n' | /usr/sbin/nas mount /dev/sdb1 2>&1); RC=$?
assert_rc 1
assert_match 'must live under /mnt' "$OUT"

t "init: a formatted disk is refused and pointed at nas mount"
seed
echo "sdc: signature" > /tmp/wipefs-out
run_nas disk init /dev/sdc
assert_rc 1
assert_match 'NOT blank' "$OUT"
assert_match 'never automates formatting' "$OUT"
assert_match 'nas mount /dev/sdc' "$OUT"
assert_nomatch 'parted' "$(cat $CALLS 2>/dev/null || :)" "nothing was partitioned"

t "init: a partition argument is refused"
seed
run_nas disk init /dev/sdb1
assert_rc 1
assert_match 'name the whole disk' "$OUT"

t "init: serial confirm mismatch aborts BEFORE any write"
seed
OUT=$(printf '2\n\n1\nWRONG\n' | /usr/sbin/nas disk init /dev/sdc 2>&1); RC=$?
assert_rc 1
assert_match 'Mismatch — nothing was written' "$OUT"
grep -q 'parted' "$CALLS" 2>/dev/null && fail "parted ran despite a failed confirm"

t "init: data role formats large-file ext4 with -i 1048576 -m 0 and chains"
seed
# answers: role=2(data) fs=(ext4 default) contents=1(large) serial=9876,
# then the CHAINED mount flow (role preset — no second role question):
# snapraid offer = n
OUT=$(printf '2\n\n1\n9876\nn\n' | /usr/sbin/nas disk init /dev/sdc 2>&1); RC=$?
assert_rc 0
assert_match 'mkfs.ext4 .*-L disk1 .*-i 1048576 -m 0 /dev/sdc1' "$(cat $CALLS)"
assert_match 'parted -s /dev/sdc mklabel gpt' "$(cat $CALLS)"
assert_match 'fstab: UUID=new-5678  /mnt/disk1' "$OUT"

t "init: nasdata role keeps -m 1; xfs skips the inode question"
seed
# a box with NO nasdata yet — the role-1 duplicate guard must not fire
printf 'LABEL=MNASCFG  /cfg  ext4  rw,noatime,nofail  0 0\n' > /etc/fstab
# answers: role=1(nasdata) fs=(ext4) contents=2(mixed) serial — the role
# is preset through the chain and nasdata gets no snapraid offer
OUT=$(printf '1\n\n2\n9876\n' | /usr/sbin/nas disk init /dev/sdc 2>&1); RC=$?
assert_rc 0
assert_match 'mkfs.ext4 .*-m 1 /dev/sdc1' "$(cat $CALLS)"
assert_nomatch '\-i 1048576' "$(cat $CALLS)" "mixed-files answer keeps default inodes"
seed
OUT=$(printf '2\nxfs\n9876\nn\n' | /usr/sbin/nas disk init /dev/sdc 2>&1); RC=$?
assert_rc 0
assert_match 'mkfs.xfs .*-L disk1' "$(cat $CALLS)"
assert_nomatch 'Contents\?' "$OUT" "xfs must not ask the ext4 inode question"

t "disk is an alias of disks"
seed
run_nas disk --json
assert_rc 0
printf '%s' "$OUT" | head -c 1 | grep -q '{' || fail "disk --json did not emit JSON"

finish
