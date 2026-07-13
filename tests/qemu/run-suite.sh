#!/bin/sh
# MountNAS QEMU test suite -- bootstrap + entry point.
#
# Designed for a fresh Alpine Linux host (e.g. a VM on Proxmox with nested
# KVM): installs/verifies dependencies, then runs pytest and writes a
# self-contained HTML report to
#   ~/mountnas-qemu-test-suite-result-YYYY-MM-DD/
#       mountnas-qemu-test-suite-result-YYYY-MM-DD.html
#
# Usage:
#   sh run-suite.sh [IMAGE.img.gz] [options] [-- pytest-args...]
#
#   IMAGE.img.gz        image under test (default: download latest release)
#   --previous FILE     previous-release image for upgrade tests
#   --tier smoke|full   smoke = ~15 min sanity subset (default: full)
#   --require-kvm       abort instead of falling back to slow TCG emulation
#   --keep-guests       keep per-test overlay disks for debugging
#   --collect           sanity mode: import + collect tests only, run nothing
#   -- ...              everything after -- goes to pytest (-k, -m, -x ...)
#
# Examples:
#   sh run-suite.sh                                   # latest release, full
#   sh run-suite.sh mountnas-beta-3.img.gz --tier smoke
#   sh run-suite.sh img.gz -- -m "not upgrade" -x

set -eu

SUITE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CACHE_DIR=${MOUNTNAS_TEST_CACHE:-"$HOME/.cache/mountnas-qemu"}
DATE=$(date +%Y-%m-%d)
RUN_DIR="$HOME/mountnas-qemu-test-suite-result-$DATE"
REPORT="$RUN_DIR/mountnas-qemu-test-suite-result-$DATE.html"

IMAGE=""
PREVIOUS=""
TIER="full"
REQUIRE_KVM=0
KEEP_GUESTS=0
COLLECT_ONLY=0

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --previous)     PREVIOUS=$2; shift 2 ;;
        --tier)         TIER=$2; shift 2 ;;
        --require-kvm)  REQUIRE_KVM=1; shift ;;
        --keep-guests)  KEEP_GUESTS=1; shift ;;
        --collect)      COLLECT_ONLY=1; shift ;;
        --)             shift; break ;;
        -h|--help)      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             echo "unknown option: $1" >&2; exit 2 ;;
        *)              IMAGE=$1; shift ;;
    esac
done
# anything left in "$@" is passed to pytest verbatim

case "$TIER" in
    smoke|full) ;;
    *) echo "ERROR: --tier must be smoke or full" >&2; exit 2 ;;
esac

note()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- packages
# Core set; ovmf is optional (UEFI tests self-skip without it).
APK_PKGS="python3 py3-pip py3-pytest py3-pexpect py3-pillow
qemu-system-x86_64 qemu-img mtools e2fsprogs sfdisk util-linux-misc
openssh-client-default openssh-keygen gzip curl ca-certificates"

if command -v apk >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    # A fresh Alpine "sys" install ships the community repo commented out, but
    # qemu, qemu-img and py3-pillow all live there.  Enable it (idempotent).
    if grep -q '^#[[:space:]]*http.*/community[[:space:]]*$' /etc/apk/repositories 2>/dev/null; then
        note "enabling the community apk repository"
        sed -i 's|^#[[:space:]]*\(http.*/community\)[[:space:]]*$|\1|' /etc/apk/repositories
        apk update >/dev/null 2>&1 || warn "apk update after enabling community failed"
    fi
    note "installing dependencies via apk"
    # shellcheck disable=SC2086
    apk add --no-cache $APK_PKGS || fail "apk add failed"
    apk add --no-cache ovmf >/dev/null 2>&1 || \
        warn "ovmf not installable; UEFI tests will be skipped"
else
    note "not root (or not Alpine); verifying dependencies are present"
    MISSING=""
    for bin in python3 qemu-system-x86_64 qemu-img mcopy mkfs.ext4 sfdisk \
               ssh ssh-keygen gzip; do
        command -v "$bin" >/dev/null 2>&1 || MISSING="$MISSING $bin"
    done
    for mod in pytest pexpect PIL; do
        python3 -c "import $mod" >/dev/null 2>&1 || MISSING="$MISSING py3:$mod"
    done
    if [ -n "$MISSING" ]; then
        echo "missing:$MISSING" >&2
        echo "on Alpine, run as root or install:" >&2
        echo "  apk add --no-cache $APK_PKGS ovmf" | tr '\n' ' ' >&2
        echo >&2
        fail "dependencies missing"
    fi
fi

# ---------------------------------------------------------------- leftover guests
# A crashed/killed previous run can leave orphaned qemu guests running (the
# harness now sets PR_SET_PDEATHSIG so this is rare, but belt-and-suspenders).
# On a small host even a couple of 4 GB orphans will thrash the box into
# unresponsiveness, so clear them before starting.
if command -v pgrep >/dev/null 2>&1 && [ -n "$(pgrep -f 'qemu-system-x86_64.*mnq-' 2>/dev/null)" ]; then
    warn "killing leftover MountNAS test guests from a previous run"
    for p in $(pgrep -f 'qemu-system-x86_64.*mnq-' 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
fi

# ---------------------------------------------------------------- RAM preflight
# MountNAS is a diskless appliance: it installs its whole userspace into a
# tmpfs RAM-root at boot, so a guest needs ~4 GB just to boot cleanly (less
# and the package install ENOSPCs the tmpfs).  Upgrade guests use 8 GB.  With
# only one guest live at a time the host needs headroom for that guest + itself.
MEM_TOTAL_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$MEM_TOTAL_MB" -gt 0 ]; then
    if [ "$MEM_TOTAL_MB" -lt 5000 ]; then
        warn "host has only ${MEM_TOTAL_MB} MB RAM.  A single MountNAS guest needs ~4 GB"
        warn "(8 GB for upgrade tests).  Below ~5 GB the box will swap-thrash and can"
        warn "wedge; upgrade tests (-m 8192) will not fit.  Recommended: 12-16 GB."
        warn "Run with -m 'not upgrade', or bump the VM's RAM."
    elif [ "$MEM_TOTAL_MB" -lt 10000 ]; then
        warn "host has ${MEM_TOTAL_MB} MB RAM; upgrade guests (-m 8192) may not fit."
        warn "12-16 GB recommended for the full tier."
    fi
fi

# ---------------------------------------------------------------- KVM
if [ -w /dev/kvm ]; then
    export MOUNTNAS_KVM=1
    note "KVM available"
else
    if [ "$REQUIRE_KVM" = "1" ]; then
        fail "/dev/kvm not available (nested virt off? kvm group?) and --require-kvm was given"
    fi
    warn "/dev/kvm not available -- falling back to TCG software emulation."
    warn "Expect a 5-8x slowdown; consider --tier smoke.  (--require-kvm aborts instead.)"
    export MOUNTNAS_TEST_TIME_SCALE=${MOUNTNAS_TEST_TIME_SCALE:-6}
fi

# ---------------------------------------------------------------- OVMF
if [ -z "${MOUNTNAS_OVMF:-}" ]; then
    for f in /usr/share/OVMF/OVMF.fd /usr/share/ovmf/OVMF.fd \
             /usr/share/ovmf/bios.efi /usr/share/edk2/x64/OVMF.fd \
             /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/qemu/edk2-x86_64-code.fd; do
        if [ -f "$f" ]; then MOUNTNAS_OVMF=$f; break; fi
    done
fi
if [ -n "${MOUNTNAS_OVMF:-}" ]; then
    export MOUNTNAS_OVMF
    note "UEFI firmware: $MOUNTNAS_OVMF"
else
    warn "no OVMF firmware found; UEFI boot tests will be skipped"
fi

# ---------------------------------------------------------------- disk space
mkdir -p "$CACHE_DIR"
AVAIL_KB=$(df -Pk "$CACHE_DIR" | awk 'NR==2 {print $4}')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
if [ "$AVAIL_GB" -lt 12 ]; then
    fail "only ${AVAIL_GB} GB free under $CACHE_DIR -- need >= 12 GB (30 GB recommended; upgrade payload disks are large)"
elif [ "$AVAIL_GB" -lt 30 ]; then
    warn "${AVAIL_GB} GB free under $CACHE_DIR; 30 GB recommended for the full tier"
fi

# ---------------------------------------------------------------- venv
VENV="$CACHE_DIR/venv"
if [ ! -x "$VENV/bin/python" ]; then
    note "creating virtualenv at $VENV"
    python3 -m venv --system-site-packages "$VENV"
fi
if ! "$VENV/bin/pip" install -q -r "$SUITE_DIR/requirements.txt"; then
    if "$VENV/bin/python" -c "import pytest_html, ansi2html" >/dev/null 2>&1; then
        warn "pip install failed but packages already present (offline rerun?)"
    else
        warn "pip install failed and pytest-html/ansi2html unavailable;"
        warn "the suite will run but the HTML report will be missing"
    fi
fi

# ---------------------------------------------------------------- run
mkdir -p "$RUN_DIR"

if [ "$COLLECT_ONLY" = "1" ]; then
    note "collect-only sanity run"
    exec "$VENV/bin/python" -m pytest "$SUITE_DIR" --collect-only -q "$@"
fi

# basetemp on the (space-checked) cache disk, NOT pytest's default under
# /tmp: /tmp is tmpfs on many hosts, and tmp_path holds every guest's qcow2
# overlays — an upgrade test writes ~5 GB of scratch there, which together
# with an 8 GB guest swap-thrashes a 16 GB host until the guest wedges.
set -- "$SUITE_DIR" -v \
    --run-dir "$RUN_DIR" \
    --basetemp "$CACHE_DIR/pytest-tmp" \
    --junitxml "$RUN_DIR/junit.xml" \
    -o "log_file=$RUN_DIR/pytest.log" -o log_file_level=DEBUG \
    "$@"
if [ -n "$IMAGE" ]; then
    [ -f "$IMAGE" ] || fail "image not found: $IMAGE"
    set -- "$@" --image "$IMAGE"
fi
[ -n "$PREVIOUS" ] && set -- "$@" --previous "$PREVIOUS"
[ "$KEEP_GUESTS" = "1" ] && set -- "$@" --keep-guests
[ "$TIER" = "smoke" ] && set -- "$@" -m smoke
if "$VENV/bin/python" -c "import pytest_html" >/dev/null 2>&1; then
    set -- "$@" --html "$REPORT" --self-contained-html
fi

note "running suite (tier=$TIER); report -> $REPORT"
RC=0
"$VENV/bin/python" -m pytest "$@" || RC=$?

echo
if [ -f "$REPORT" ]; then
    note "report: $REPORT"
fi
[ -f "$RUN_DIR/summary.json" ] && note "summary: $RUN_DIR/summary.json"
exit "$RC"
