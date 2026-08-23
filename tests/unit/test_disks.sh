#!/bin/sh
# nas disks: inventory rendering and the paste-ready fstab lines, from a
# fixed lsblk JSON. A hostile label proves the jq path never evals user data.
. "$(dirname "$0")/harness.sh"

LSBLK='{"blockdevices":[
 {"name":"sda","type":"disk","size":"4T","fstype":null,"label":null,"uuid":null,"mountpoint":null,"fsavail":null,"fsuse%":null,
  "vendor":"ATA","model":"WDC WD40EFRX","serial":"WD-1234","rev":"82.0","tran":"sata","rota":true,
  "children":[
   {"name":"sda1","type":"part","size":"4T","fstype":"xfs","label":"$(touch /tmp/pwned)","uuid":"1111-aaaa","mountpoint":"/mnt/disk1","fsavail":"3T","fsuse%":"25%"}]},
 {"name":"nvme0n1","type":"disk","size":"500G","fstype":null,"label":null,"uuid":null,"mountpoint":null,"fsavail":null,"fsuse%":null,
  "vendor":null,"model":"Samsung 970","serial":"S4EV","rev":"2B2Q","tran":"nvme","rota":false,
  "children":[
   {"name":"nvme0n1p1","type":"part","size":"500G","fstype":"ext4","label":"nasdata","uuid":"2222-bbbb","mountpoint":null,"fsavail":null,"fsuse%":null}]},
 {"name":"sdb","type":"disk","size":"2T","fstype":null,"label":null,"uuid":null,"mountpoint":null,"fsavail":null,"fsuse%":null,
  "vendor":"ATA","model":"ST2000","serial":"Z5","rev":"CC43","tran":"usb","rota":true},
 {"name":"sdz","type":"disk","size":"8G","fstype":null,"label":null,"uuid":null,"mountpoint":null,"fsavail":null,"fsuse%":null,
  "vendor":"SanDisk","model":"Ultra","serial":"4C53","rev":"1.00","tran":"usb","rota":false,
  "children":[
   {"name":"sdz1","type":"part","size":"3.5G","fstype":"vfat","label":"BOOT","uuid":"ABCD-0001","mountpoint":null,"fsavail":null,"fsuse%":null},
   {"name":"sdz2","type":"part","size":"500M","fstype":"ext4","label":"MNASCFG","uuid":"3333-cccc","mountpoint":"/cfg","fsavail":"400M","fsuse%":"10%"}]},
 {"name":"zram0","type":"disk","size":"2G","fstype":null,"label":null,"uuid":null,"mountpoint":"[SWAP]","fsavail":null,"fsuse%":null,
  "vendor":null,"model":null,"serial":null,"rev":null,"tran":null,"rota":false}
]}'
stub lsblk "case \"\$*\" in *pkname*) echo sdz ;; *) cat <<'__J__'
$LSBLK
__J__
esac"
stub findfs 'case "$1" in LABEL=BOOT) echo /dev/sdz1 ;; *) exit 1 ;; esac'
stub hdparm 'case "$2" in /dev/sda) echo " drive state is:  standby" ;; *) echo " drive state is:  active/idle" ;; esac'
printf 'LABEL=MNASCFG  /cfg  ext4  rw,noatime,nofail  0 0\nUUID=1111-aaaa  /mnt/disk1  xfs  rw,noatime,nofail  0 2\n' > /etc/fstab
rm -f /tmp/pwned

t "inventory: every real disk, the boot USB tagged, zram hidden"
run_nas disks
assert_rc 0
assert_match '^-- sda  4T  sata HDD  temp:standby' "$OUT"
assert_match 'ATA WDC WD40EFRX  SN:WD-1234  fw:82.0' "$OUT"
assert_match '^-- nvme0n1  500G  nvme SSD' "$OUT"
assert_match '^-- sdz  8G  usb SSD  temp:.*\*BOOT USB\*' "$OUT"
assert_nomatch 'zram0' "$OUT"
assert_match 'sda1 .*xfs .*-> /mnt/disk1  \(3T free, 25% used\)' "$OUT"
assert_match 'UUID=1111-aaaa' "$OUT"

t "a hostile label is printed, never executed"
[ ! -e /tmp/pwned ] || fail "label was evaluated as shell"
assert_match '\$\(touch /tmp/pwned\)' "$OUT"

t "a blank disk gets a mkfs hint"
assert_match 'blank — no filesystem; create one first, e.g. mkfs.ext4 -L data1 /dev/sdb' "$OUT"

t "paste-ready lines: nasdata first, the boot USB and configured disks skipped"
assert_match '^  UUID=2222-bbbb  /mnt/nasdata  ext4  rw,noatime,nofail  0 2   # Samsung 970 SN:S4EV \(edit mountpoint\)' "$OUT"
assert_nomatch '^  UUID=ABCD-0001' "$OUT"
assert_nomatch 'UUID=3333-cccc  /mnt' "$OUT"
assert_nomatch 'UUID=1111-aaaa  /mnt/disk' "$OUT"

t "paste-ready lines: with nasdata configured the next free /mnt/diskN is used"
printf 'UUID=9999-ffff  /mnt/nasdata  ext4  rw,noatime,nofail  0 2\n' >> /etc/fstab
run_nas disks
assert_match '^  UUID=2222-bbbb  /mnt/disk2 ' "$OUT"

t "a commented-out fstab entry gets its line back"
sed -i 's|^UUID=1111-aaaa|#UUID=1111-aaaa|' /etc/fstab
run_nas disks
assert_match '^  UUID=1111-aaaa  /mnt/disk1 ' "$OUT"

t "--json: shape, boot flag, temps, in_fstab"
printf 'LABEL=MNASCFG  /cfg  ext4  rw,noatime,nofail  0 0\nUUID=1111-aaaa  /mnt/disk1  xfs  rw,noatime,nofail  0 2\n' > /etc/fstab
run_nas disks --json
assert_rc 0
printf '%s' "$OUT" | jq -e . >/dev/null || fail "not JSON: $OUT"
assert_eq "sdz" "$(printf '%s' "$OUT" | jq -r .boot_usb)"
assert_eq "sda nvme0n1 sdb sdz" "$(printf '%s' "$OUT" | jq -r '[.disks[].name] | join(" ")')"
assert_eq "true" "$(printf '%s' "$OUT" | jq -r '.disks[] | select(.name=="sdz") | .boot_usb')"
assert_eq "standby" "$(printf '%s' "$OUT" | jq -r '.disks[] | select(.name=="sda") | .temp')"
assert_eq "true" "$(printf '%s' "$OUT" | jq -r '.disks[0].partitions[0].in_fstab')"
assert_eq "false" "$(printf '%s' "$OUT" | jq -r '.disks[1].partitions[0].in_fstab')"
assert_eq '$(touch /tmp/pwned)' "$(printf '%s' "$OUT" | jq -r '.disks[0].partitions[0].label')"

finish
