"""Category L -- SnapRAID data-safety under real failure.

Category E proves the happy path (a clean sync, the threshold gate, a
single-file fix).  This tier proves the promises a NAS owner actually
depends on, against a REAL array with REAL parity:

  * a failed disk (the supervisor's read-only placeholder) must REFUSE a
    sync -- an empty placeholder reads to snapraid as "every file deleted",
    and syncing that writes the deletion into parity
  * a missing disk must refuse the same way
  * corrupted parity must be DETECTED, not silently trusted
  * silent data corruption (bit rot) must be detected AND repaired
  * a destroyed disk must be rebuildable from parity, byte for byte
  * a blocked run must actually reach the notification sinks

Every test starts from a synced array and asserts parity is untouched by a
refusal, because "the sync was refused" is worthless if parity moved anyway.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from lib.guest import DiskSpec, push_nas_tree
from lib import images

FILES_DIR = Path(__file__).resolve().parent.parent.parent / "mountnas-tools" / "files"

# 40 files is well under DEL_THRESHOLD (100): these tests must exercise the
# MOUNT preflight and the integrity paths, never the delete gate that
# category E already covers.
N_FILES = 40


@pytest.fixture
def array_guest(guest_factory, overlay_disks, golden, tmp_path):
    """A guest with a synced single-parity array: d1 on /mnt/disk1, parity on
    /mnt/parity1, content copies on both (the copy on parity is what makes a
    whole-disk rebuild possible at all).  Returns the guest."""
    def make():
        sysd, datad = overlay_disks()
        extras = [images.create_blank_qcow2(tmp_path / f"arr{i}.qcow2", "4G")
                  for i in range(2)]
        disks = [DiskSpec(str(sysd)), DiskSpec(str(datad), serial="NASDATA0")]
        disks += [DiskSpec(str(p), serial=f"ARR{i}") for i, p in enumerate(extras)]
        g = guest_factory(disks, name="snapraid", ssh_key=golden.ssh_key,
                          throwaway=[sysd, datad, *extras])
        g.wait_ssh()
        # run the REPO's tools, not the released ones
        push_nas_tree(g, FILES_DIR)
        g.push(FILES_DIR / "snapraid-maint", "/usr/libexec/mountnas/snapraid-maint")
        g.run("chmod 755 /usr/libexec/mountnas/snapraid-maint", check=True)

        g.run("mkfs.ext4 -Fq -L disk1 /dev/vdc", timeout=180, check=True)
        g.run("mkfs.ext4 -Fq -L parity1 /dev/vdd", timeout=180, check=True)
        g.run("printf '%s\\n' 'LABEL=disk1 /mnt/disk1 ext4 rw,noatime,nofail 0 2'"
              " >> /etc/fstab", check=True)
        g.run("printf '%s\\n' 'LABEL=parity1 /mnt/parity1 ext4 rw,noatime,nofail 0 2'"
              " >> /etc/fstab", check=True)
        g.run("rc-service mountnas restart", timeout=240, check=True)
        g.poll_until("mountpoint -q /mnt/parity1", timeout=120, desc="parity mounted")
        g.run("cat > /etc/snapraid.conf <<'EOF'\n"
              "parity /mnt/parity1/snapraid.parity\n"
              "content /mnt/disk1/snapraid.content\n"
              "content /mnt/parity1/snapraid.content\n"
              "data d1 /mnt/disk1/\n"
              "EOF", check=True)
        g.run(f"mkdir -p /mnt/disk1/docs && for i in $(seq 1 {N_FILES}); do"
              " head -c 65536 /dev/urandom > /mnt/disk1/docs/f$i.bin; done",
              timeout=180, check=True)
        r = g.run("NO_COLOR=1 nas snapraid run", timeout=900)
        assert r.rc == 0, f"array setup sync failed rc={r.rc}:\n{r.out[-3000:]}"
        return g
    return make


def _parity_fingerprint(g) -> str:
    return g.run("md5sum /mnt/parity1/snapraid.parity | cut -d' ' -f1",
                 timeout=300, check=True).out.strip()


# ------------------------------------------------------- refusal: failed disk

@pytest.mark.slow
def test_preflight_refuses_supervisor_placeholder(array_guest):
    """THE data-loss path fixed in 1.0.1.  When a data disk fails to mount the
    supervisor covers its mountpoint with a read-only 'mountnas-blocked'
    tmpfs.  That placeholder IS a mountpoint, so a bare mountpoint test
    accepted it -- and snapraid then read an EMPTY directory as "every file on
    d1 was deleted".  With few enough files the delete gate does not catch it
    either, so the deletion would be synced into parity and the one copy that
    could restore the data destroyed.  The preflight must refuse, and parity
    must not move."""
    g = array_guest()
    before = _parity_fingerprint(g)

    g.run("umount /mnt/disk1", check=True)
    g.run("mount -t tmpfs -o ro,size=4k,mode=0555 mountnas-blocked /mnt/disk1",
          check=True)
    # precondition: it really does look mounted to a naive test
    assert g.run("mountpoint -q /mnt/disk1").rc == 0
    assert g.run("ls /mnt/disk1/docs").rc != 0, "placeholder is not empty?!"

    r = g.run("NO_COLOR=1 nas snapraid run", timeout=300)
    assert r.rc == 2, f"a placeholdered disk must fail the preflight, rc={r.rc}:\n{r.out[-2000:]}"
    assert "not mounted" in r.out.lower() or "REFUSED" in r.out, r.out
    assert _parity_fingerprint(g) == before, "parity CHANGED on a refused run"
    g.run("umount /mnt/disk1 && mount /mnt/disk1", check=True)


@pytest.mark.slow
def test_preflight_refuses_missing_disk(array_guest):
    """A data disk that is simply not mounted (the array path lands on the RAM
    root) must refuse for the same reason, with parity untouched."""
    g = array_guest()
    before = _parity_fingerprint(g)
    g.run("umount /mnt/disk1", check=True)
    r = g.run("NO_COLOR=1 nas snapraid run", timeout=300)
    assert r.rc == 2, f"an unmounted disk must fail the preflight, rc={r.rc}:\n{r.out[-2000:]}"
    assert _parity_fingerprint(g) == before, "parity CHANGED on a refused run"
    # and nas snapraid status must say so rather than showing it healthy
    r = g.run("NO_COLOR=1 nas snapraid status", timeout=60)
    assert "MISSING" in r.out or "BLOCKED" in r.out, r.out
    g.run("mount /mnt/disk1", check=True)


# ------------------------------------------------------------ integrity: rot

@pytest.mark.slow
def test_bitrot_is_detected_and_repaired(array_guest):
    """Silent data corruption: flip bytes inside a file WITHOUT changing its
    size or mtime, so nothing in the filesystem notices.  A scrub must find
    it, and fix must restore the original bytes from parity.  This is the
    whole reason a scrub exists."""
    g = array_guest()
    want = g.run("md5sum /mnt/disk1/docs/f1.bin | cut -d' ' -f1", check=True).out.strip()
    ts = g.run("stat -c %Y /mnt/disk1/docs/f1.bin", check=True).out.strip()

    # BASELINE first. Detection has to be a DIFFERENTIAL, because every
    # snapraid scrub prints "0 data errors" and "No error detected" -- so any
    # assertion on the word "error" passes on a perfectly healthy array and
    # proves nothing. Establish clean, corrupt, then require the verdict to
    # change. The exit status is the signal that actually discriminates.
    base = g.run("snapraid scrub -p 100 -o 0", timeout=900)
    assert base.rc == 0, \
        f"the array was not clean before corrupting it:\n{base.out[-2000:]}"

    # corrupt in place: same size, same mtime -> invisible to snapraid's
    # timestamp-based change detection, visible only to a checksum
    g.run("dd if=/dev/urandom of=/mnt/disk1/docs/f1.bin bs=1024 seek=8 count=4"
          " conv=notrunc status=none", check=True)
    g.run(f"touch -d @{ts} /mnt/disk1/docs/f1.bin", check=True)
    assert g.run("md5sum /mnt/disk1/docs/f1.bin | cut -d' ' -f1",
                 check=True).out.strip() != want, "corruption did not take"

    r = g.run("snapraid scrub -p 100 -o 0", timeout=900)
    assert r.rc != 0, \
        f"a full scrub did not notice the silent corruption (rc=0):\n{r.out[-3000:]}"
    g.screenshot("snapraid-scrub-detected-bitrot")

    # REPAIR: the targeted per-file recovery, which is what the docs tell a
    # user to run once a scrub has named the file.  'fix -e' is deliberately
    # NOT used here: it repairs blocks marked bad in a previous run, and
    # whether that marker survives is snapraid's bookkeeping, not ours -- the
    # claim under test is that parity can put the original bytes back.
    r = g.run("snapraid fix -f docs/f1.bin", timeout=900)
    assert r.rc == 0, f"snapraid fix -f rc={r.rc}:\n{r.out[-3000:]}"
    got = g.run("md5sum /mnt/disk1/docs/f1.bin | cut -d' ' -f1", check=True).out.strip()
    assert got == want, f"fix did not restore the original content:\n{r.out[-2000:]}"


# -------------------------------------------------------- integrity: parity

@pytest.mark.slow
def test_corrupted_parity_is_detected(array_guest):
    """Parity itself can rot.  Corrupting it must be DETECTED by a scrub
    rather than silently trusted -- a NAS that believes in bad parity gives
    false confidence, which is worse than knowing you are unprotected."""
    g = array_guest()
    # clean baseline, so a non-zero verdict below is attributable to OUR
    # corruption and not to a pre-existing fault
    base = g.run("snapraid scrub -p 100 -o 0", timeout=900)
    assert base.rc == 0, \
        f"the array was not clean before corrupting parity:\n{base.out[-2000:]}"
    g.run("dd if=/dev/urandom of=/mnt/parity1/snapraid.parity bs=1024 seek=64"
          " count=16 conv=notrunc status=none", check=True)
    r = g.run("snapraid scrub -p 100 -o 0", timeout=900)
    # rc ALONE. "0 data errors" and "No error detected" appear in every clean
    # scrub, so an 'or "error" in out' disjunct can never fail.
    assert r.rc != 0, \
        f"corrupted parity was not detected by a full scrub (rc=0):\n{r.out[-3000:]}"
    g.screenshot("snapraid-corrupt-parity-detected")
    # the array is repairable: a fix rewrites parity from the intact data
    r = g.run("snapraid fix -e", timeout=900)
    assert r.rc == 0, f"fix after parity corruption rc={r.rc}:\n{r.out[-3000:]}"
    r = g.run("snapraid scrub -p 100 -o 0", timeout=900)
    assert r.rc == 0, f"array still unhealthy after fix:\n{r.out[-3000:]}"


# ------------------------------------------------------- the whole promise

@pytest.mark.slow
def test_whole_disk_loss_rebuilds_from_parity(array_guest):
    """The promise the whole feature exists for: a data disk is destroyed and
    every file on it comes back from parity, byte for byte.

    It also proves the content-copy rule earns its keep -- the copy on the
    PARITY disk is the only one that survives, and without it the array
    could not be rebuilt at all."""
    g = array_guest()
    want = g.run("cd /mnt/disk1 && find docs -type f | sort | xargs md5sum",
                 timeout=300, check=True).out.strip()
    assert want.count("\n") + 1 == N_FILES, "fingerprint did not cover every file"

    # destroy the disk completely, then bring back an empty filesystem
    g.run("umount /mnt/disk1", check=True)
    g.run("mkfs.ext4 -Fq -L disk1 /dev/vdc", timeout=180, check=True)
    g.run("mount /mnt/disk1", check=True)
    assert g.run("ls /mnt/disk1/docs").rc != 0, "disk was not actually wiped"
    # the surviving content copy lives on the parity disk
    g.run("test -s /mnt/parity1/snapraid.content", check=True)

    r = g.run("snapraid -d d1 -l /tmp/fix.log fix", timeout=1800)
    assert r.rc == 0, f"rebuild rc={r.rc}:\n{r.out[-3000:]}"
    g.screenshot("snapraid-disk-rebuilt")

    got = g.run("cd /mnt/disk1 && find docs -type f | sort | xargs md5sum",
                timeout=300, check=True).out.strip()
    assert got == want, "rebuilt disk does not match the original content"


# ------------------------------------------------------------- notification

@pytest.mark.slow
def test_blocked_run_alerts_through_sinks(array_guest, http_server):
    """A blocked sync is only useful if somebody hears about it.  The runner
    must push the BLOCKED verdict out through the configured notify sinks."""
    g = array_guest()
    g.run(f"printf '%s\\n' 'webhook:http://10.0.2.2:{http_server.port}/snapraid'"
          " > /etc/mountnas/notify.conf", check=True)
    # cross the delete gate: DEL_THRESHOLD defaults to 100
    g.run("mkdir -p /mnt/disk1/bulk && for i in $(seq 1 150); do"
          " head -c 1024 /dev/urandom > /mnt/disk1/bulk/b$i.bin; done",
          timeout=180, check=True)
    r = g.run("NO_COLOR=1 nas snapraid run", timeout=900)
    assert r.rc == 0, f"adding files should sync cleanly, rc={r.rc}:\n{r.out[-2000:]}"
    g.run("rm -rf /mnt/disk1/bulk", check=True)

    before = _parity_fingerprint(g)
    r = g.run("NO_COLOR=1 nas snapraid run", timeout=900)
    assert r.rc == 1, f"a 150-file delete must BLOCK, rc={r.rc}:\n{r.out[-2000:]}"
    assert _parity_fingerprint(g) == before, "parity CHANGED on a blocked run"

    posts = http_server.wait_for_post(1, timeout=g.cfg.scaled(120))
    body = posts[0].body
    if isinstance(body, (bytes, bytearray)):
        body = body.decode("utf-8", "replace")
    assert "BLOCK" in body.upper(), f"alert did not name the verdict: {body}"
