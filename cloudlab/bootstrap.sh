#!/usr/bin/env bash
# Node bootstrap for the consolidated DC simulator testbed.
# Runs as a CloudLab startup service on every boot, on every node.
#
# Usage: bootstrap.sh <ctl|wk> --pypy-version V
#                              [--sim-hosts N --sim-nodes T --wk-slots a,b,c]
#                              (the last three are passed to ctl1 only)
#
# Roles:
#   ctl  ctl1. Redis coordination bus, simulator master, AND a worker.
#        With one machine it is the entire testbed.
#   wk   an additional worker machine.
#
# What this installs: the RUNTIME only -- PyPy (pinned), its packages, Redis
# on ctl1, a raised file-descriptor limit, a data filesystem. It does NOT
# install the simulator; that arrives over rsync from the laptop afterwards
# (consolidated-dc-simulator/tests/sync.sh). The authority on the Python
# environment is the simulator's own tests/distributed/
# setup_sim_environment.sh, whose pinned versions this mirrors so a node is
# usable before the first sync. That script is idempotent and can be re-run.
#
# Every check below distinguishes MISSING from WRONG and says which. A check
# that reports a verdict about the code when the truth was a missing input
# has cost this project more time than any bug.
set -uo pipefail

ROLE="${1:?usage: bootstrap.sh <ctl|wk> [opts]}"; shift || true
PYPY_VERSION="pypy3.10-v7.3.17-linux64"
SIM_HOSTS=1; SIM_NODES=20; WK_SLOTS="none"
while [ $# -gt 0 ]; do
    case "$1" in
        --pypy-version) PYPY_VERSION="$2"; shift 2 ;;
        --sim-hosts)    SIM_HOSTS="$2";    shift 2 ;;
        --sim-nodes)    SIM_NODES="$2";    shift 2 ;;
        --wk-slots)     WK_SLOTS="$2";     shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Frozen with the profile's address plan. Changing either invalidates every
# mod_op.config already generated.
CTL_LAN_IP="10.10.1.10"
REDIS_PORT=6379
REDIS_DB=5
# Matches the simulator's own default (mod_op.sh:16). A disposable testbed on
# an isolated control network; not a pattern for anything internet-facing.
REDIS_PASS="1qaz2wsx"

PYPY_PACKAGES="${SIM_PYPY_PACKAGES:-sortedcontainers redis numpy}"
PYPY_PREFIX=/opt/pypy
PYPY_BIN=/usr/local/bin/pypy3

REPO=/local/repository
STATE=/local/testbed
LOGDIR="$STATE/logs"
# ★ NOT /mnt/shared-storage. Nothing here is shared between nodes: every node
#   mounts its own local disk. The other name asserts a property the path has
#   never had, on CloudLab or on AWS, and it has already cost this project
#   days of chasing results that were only ever on one machine.
SIMDATA=/mnt/simdata

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo -H"; fi

$SUDO mkdir -p "$LOGDIR"
$SUDO chmod 0777 "$STATE" "$LOGDIR"
exec > >(tee -a "$LOGDIR/bootstrap.log") 2>&1
echo "=== bootstrap role=$ROLE host=$(hostname) at $(date -Is) ==="
echo "    pypy=$PYPY_VERSION sim_hosts=$SIM_HOSTS sim_nodes=$SIM_NODES wk_slots=$WK_SLOTS"

fail=0
note_fail() { echo "FAILED: $*"; fail=1; }

# ------------------------------------------------------------------ apt ---
export DEBIAN_FRONTEND=noninteractive
for _ in 1 2 3; do $SUDO apt-get update -qq && break || sleep 5; done

# Small on purpose: enough for the user-space PyPy tarball and for building
# any wheel that has no pp310 build. chrony because a multi-machine run
# correlates timestamps across nodes.
$SUDO apt-get install -y -qq \
    ca-certificates wget curl bzip2 tar xz-utils \
    python3 chrony jq rsync \
    build-essential pkg-config libffi-dev \
    redis-tools sysstat >/dev/null || note_fail "apt package install"

$SUDO systemctl enable --now chrony >/dev/null 2>&1 || \
    $SUDO systemctl enable --now chronyd >/dev/null 2>&1 || true
$SUDO chronyc makestep >/dev/null 2>&1 || true

# -------------------------------------------------------------- storage ---
# The CloudLab root filesystem is about 64 GB. A run's logs, per-epoch
# telemetry and collected data outgrow that. Find the largest unused raw
# disk and put $SIMDATA on it.
#
# No Blockstore is declared in the profile, deliberately: LVM stripes a
# blockstore across EVERY device a node has, so on mixed flash half of every
# fsync lands on the slow device. It looks fine in df and appears in no
# chart. If you ever add one, check `lvs -o +stripes,devices` on the live
# node -- there is no profile parameter that pins it to a device.
setup_simdata() {
    local rootdisk dev fstype
    $SUDO mkdir -p "$SIMDATA"
    if mountpoint -q "$SIMDATA"; then
        echo "simdata already mounted at $SIMDATA"; return 0
    fi
    rootdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1 || true)
    dev=$(lsblk -rno NAME,TYPE,FSTYPE,MOUNTPOINT | \
          awk -v rd="$rootdisk" '($2=="disk") && $3=="" && $4=="" && $1!=rd {print $1}' | \
          while read -r d; do
              echo "$(lsblk -bdno SIZE "/dev/$d" 2>/dev/null || echo 0) $d"
          done | sort -rn | head -1 | awk '{print $2}')
    if [ -z "$dev" ] || [ ! -b "/dev/$dev" ]; then
        echo "MISSING: no spare disk on this node (not an error -- this type"
        echo "         may have only a root disk)"
        return 1
    fi
    # Probe as root. An unprivileged blkid cannot open the device and exits 0
    # with no output, which reads as "filesystem present", skips the mkfs,
    # and then fails to mount a raw disk.
    fstype=$($SUDO blkid -o value -s TYPE "/dev/$dev" 2>/dev/null || true)
    case "$fstype" in
        ext2|ext3|ext4|xfs) echo "/dev/$dev already carries $fstype" ;;
        *) echo "formatting /dev/$dev (found ${fstype:-no filesystem})"
           $SUDO mkfs.ext4 -q -F "/dev/$dev" || return 1 ;;
    esac
    if ! $SUDO mount "/dev/$dev" "$SIMDATA"; then
        echo "mount failed; reformatting /dev/$dev once and retrying"
        $SUDO mkfs.ext4 -q -F "/dev/$dev" || return 1
        $SUDO mount "/dev/$dev" "$SIMDATA" || return 1
    fi
    grep -q " $SIMDATA " /etc/fstab || \
        echo "/dev/$dev $SIMDATA ext4 defaults,nofail 0 2" | $SUDO tee -a /etc/fstab >/dev/null
    echo "simdata: /dev/$dev -> $SIMDATA"
    return 0
}
if ! setup_simdata; then
    echo "WARNING: $SIMDATA stays on the root filesystem (~64 GB)."
    echo "         Expect it to fill on a long run; collect results sooner."
fi
$SUDO mkdir -p "$SIMDATA/runs" "$SIMDATA/logs" "$SIMDATA/traces"
$SUDO chmod -R 0777 "$SIMDATA"

# --------------------------------------------------------------- limits ---
# The simulator opens a file descriptor per simulated node per worker and
# then some; run_with_high_ulimit.sh raises the SOFT limit to the HARD one,
# so the hard limit is what actually has to be large. Raised for every
# account and for systemd units, because a login shell and a service get
# their limits from different places and only fixing one is the usual bug.
if ! grep -q 'simulator testbed' /etc/security/limits.d/99-simulator.conf 2>/dev/null; then
    $SUDO tee /etc/security/limits.d/99-simulator.conf >/dev/null <<'LIM'
# simulator testbed: the run raises its soft limit to this hard one
*   soft   nofile   131072
*   hard   nofile   1048576
*   soft   nproc    65535
*   hard   nproc    131072
LIM
fi
$SUDO mkdir -p /etc/systemd/system.conf.d
$SUDO tee /etc/systemd/system.conf.d/99-simulator.conf >/dev/null <<'SYS'
[Manager]
DefaultLimitNOFILE=131072:1048576
DefaultLimitNPROC=65535:131072
SYS
$SUDO systemctl daemon-reexec >/dev/null 2>&1 || true

# ----------------------------------------------------------------- pypy ---
# Pinned. An unpinned runtime that moves mid-campaign changes the numbers,
# and the symptom never points at the cause.
install_pypy() {
    local url="https://downloads.python.org/pypy/${PYPY_VERSION}.tar.bz2"
    local archive="/tmp/${PYPY_VERSION}.tar.bz2"
    local target="${PYPY_PREFIX}/${PYPY_VERSION}"
    if [ -x "${target}/bin/pypy3" ]; then
        echo "PyPy already present: ${target}"
    else
        $SUDO mkdir -p "$PYPY_PREFIX"
        echo "downloading $url"
        local ok=0
        for _ in 1 2 3; do
            if curl -fL --retry 3 -o "$archive" "$url"; then ok=1; break; fi
            sleep 5
        done
        [ "$ok" -eq 1 ] || { echo "MISSING: could not download $url"; return 1; }
        $SUDO tar -xjf "$archive" -C "$PYPY_PREFIX" || return 1
        rm -f "$archive"
    fi
    [ -x "${target}/bin/pypy3" ] || { echo "WRONG: ${target}/bin/pypy3 is not executable after extraction"; return 1; }
    $SUDO ln -sfn "${target}/bin/pypy3" "$PYPY_BIN"
    "$PYPY_BIN" --version || return 1
    return 0
}
if install_pypy; then
    "$PYPY_BIN" -m ensurepip --default-pip >/dev/null 2>&1 || true
    $SUDO "$PYPY_BIN" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || \
        echo "WARNING: pip self-upgrade failed; continuing with the bundled pip"
    # shellcheck disable=SC2086
    if $SUDO "$PYPY_BIN" -m pip install --quiet $PYPY_PACKAGES; then
        # Record what was actually resolved. Unpinned today (matching the
        # simulator's own script); this file is what lets a past run be
        # reproduced, and what to copy from when a campaign needs pinning.
        $SUDO "$PYPY_BIN" -m pip freeze 2>/dev/null \
            | $SUDO tee "$STATE/sim-python-freeze.txt" >/dev/null
        echo "python packages installed; resolved versions in $STATE/sim-python-freeze.txt"
    else
        note_fail "pypy package install ($PYPY_PACKAGES)"
    fi
else
    note_fail "PyPy install"
fi

# ------------------------------------------------------- experiment LAN ---
# The EXPERIMENT-LAN address only. A CloudLab node has two interfaces and the
# other one -- the control network we ssh in on -- is PUBLICLY ROUTABLE. Any
# service that binds without naming an interface binds that one too.
lan_ip() {
    ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^10\.10\.1\./ {split($4,a,"/"); print a[1]; exit}'
}

# With more than one machine the LAN address is load-bearing: Redis binds to
# it and the workers reach ctl1 over it. Interfaces are not necessarily up
# when this service runs, so wait -- bounded, and say which it was.
wait_for_lan_ip() {
    local waited=0 found
    while [ "$waited" -lt 300 ]; do
        found="$(lan_ip)"
        [ -n "$found" ] && { echo "$found"; return 0; }
        sleep 5; waited=$((waited + 5))
    done
    return 1
}

LAN_IP="$(lan_ip)"
if [ -z "$LAN_IP" ] && [ "$SIM_HOSTS" -gt 1 ]; then
    echo "experiment-LAN address not up yet; waiting"
    LAN_IP="$(wait_for_lan_ip || true)"
fi
if [ -n "$LAN_IP" ]; then
    echo "experiment-LAN address: $LAN_IP"
elif [ "$SIM_HOSTS" -gt 1 ]; then
    echo "MISSING: no 10.10.1.x address on this node after 300s, but the"
    echo "         profile allocated $SIM_HOSTS machines. Check the manifest"
    echo "         for this node's interface."
else
    echo "no experiment LAN, as expected for a single-machine testbed"
fi

# ---------------------------------------------------------------- redis ---
# ctl1 only. Every worker, on this node and on the others, talks to it.
if [ "$ROLE" = "ctl" ]; then
    $SUDO apt-get install -y -qq redis-server >/dev/null || note_fail "redis-server install"
    # A drop-in, not an edit of the generated config: a sed against generated
    # text silently matches nothing when the package's defaults change, and
    # that failure mode has cost this project a multi-day hunt before.
    $SUDO mkdir -p /etc/redis/redis.conf.d 2>/dev/null || true
    # ★ NEVER 0.0.0.0. A CloudLab node has two interfaces, and the control
    #   network -- the one we ssh in on -- is PUBLICLY ROUTABLE (ctl1 was
    #   128.105.145.221 on the last allocation). 0.0.0.0 would publish this
    #   Redis, with a password that lives in a git repository, to the open
    #   internet, where open Redis is scanned for continuously. Whether the
    #   site firewall happens to block 6379 is not the standard to design to:
    #   the cost of binding explicitly is zero and the cost of being wrong
    #   lands on the account and the IP that rules T1-T5 exist to protect.
    #
    #   Loopback always (everything on ctl1 talks to it that way), plus THIS
    #   node's experiment-LAN address when there is one. No LAN address means
    #   a single-machine testbed, where loopback is the whole story. If the
    #   LAN address is genuinely missing on a multi-machine allocation we bind
    #   loopback alone and the workers fail loudly -- failing closed, never
    #   open.
    redis_binds="127.0.0.1"
    if [ -n "$LAN_IP" ]; then
        redis_binds="127.0.0.1 $LAN_IP"
    elif [ "$SIM_HOSTS" -gt 1 ]; then
        echo "MISSING: binding Redis to loopback only -- this node has no"
        echo "         experiment-LAN address and the other machines will not"
        echo "         reach it. Fix the interface, then re-run this script."
    fi
    # protected-mode is left at its default (on). It is inert once a bind list
    # and a password are set, and turning it off buys nothing here.
    $SUDO tee /etc/redis/redis-simulator.conf >/dev/null <<CONF
# simulator testbed overrides, included from redis.conf
bind ${redis_binds}
port ${REDIS_PORT}
requirepass ${REDIS_PASS}
databases 16
save ""
appendonly no
maxmemory-policy noeviction
CONF
    if ! grep -q 'redis-simulator.conf' /etc/redis/redis.conf 2>/dev/null; then
        echo "include /etc/redis/redis-simulator.conf" | \
            $SUDO tee -a /etc/redis/redis.conf >/dev/null
    fi
    $SUDO systemctl enable redis-server >/dev/null 2>&1 || true
    $SUDO systemctl restart redis-server || note_fail "redis-server restart"
fi

# ------------------------------------------------------- self-registration ---
# Each node reports its OWN facts -- the $HOSTNAME the simulator will key on,
# its LAN address, and how many logical cpus it actually has. That is the
# whole point: the profile never has to know, and a heterogeneous allocation
# is described by the machines themselves rather than guessed at from a
# hardware type. make-sim-config.sh on ctl1 reads these back.
#
# $HOSTNAME is captured exactly as bash reports it, because mod_op.sh indexes
# arr_host_role by that same value. A short name here and an FQDN there is
# precisely how a config silently matches no host.
register() {
    local host cpus mem_kb ip redis_target
    host="$(hostname)"
    cpus="$(nproc 2>/dev/null || echo 1)"
    mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    ip="$LAN_IP"
    # By ROLE, never by host count. Redis lives on ctl1: ctl1 reaches it on
    # loopback, every worker reaches it across the experiment LAN. Deciding
    # this from SIM_HOSTS instead would send a worker to its own loopback the
    # moment that count was not passed down to it.
    if [ "$ROLE" = "ctl" ]; then redis_target="127.0.0.1"; else redis_target="$CTL_LAN_IP"; fi

    $SUDO tee "$STATE/sim-node-facts" >/dev/null <<FACTS
hostname=$host
role=$ROLE
lan_ip=${ip:-none}
cpus=$cpus
mem_kb=$mem_kb
FACTS

    # Redis may not be up yet: node boot order is not ordered. Wait, bounded,
    # and say plainly which of the two it was if it never arrives.
    local waited=0
    while [ "$waited" -lt 900 ]; do
        if redis-cli -h "$redis_target" -p "$REDIS_PORT" -a "$REDIS_PASS" \
             -n "$REDIS_DB" ping 2>/dev/null | grep -q PONG; then
            redis-cli -h "$redis_target" -p "$REDIS_PORT" -a "$REDIS_PASS" \
                -n "$REDIS_DB" hset "simnodes:$host" \
                hostname "$host" role "$ROLE" lan_ip "${ip:-none}" \
                cpus "$cpus" mem_kb "$mem_kb" \
                registered_at "$(date -Is)" >/dev/null 2>&1 \
                && { echo "registered $host (cpus=$cpus mem_kb=$mem_kb ip=${ip:-none}) with redis at $redis_target"; return 0; }
            echo "WRONG: redis at $redis_target answers PING but refused the write"
            return 1
        fi
        sleep 10; waited=$((waited + 10))
    done
    echo "MISSING: redis at $redis_target never answered in ${waited}s."
    echo "         This node's facts are in $STATE/sim-node-facts; re-run"
    echo "         'bash $REPO/cloudlab/register-sim-node.sh' once ctl1 is up."
    return 1
}
register || note_fail "registration with redis"

# ------------------------------------------------------------------ env ---
$SUDO tee "$STATE/sim-env.sh" >/dev/null <<ENV
# Source this before driving the simulator on this node.
export SIM_PYTHON=${PYPY_BIN}
export SIM_CONTROL_PYTHON=python3
export REDIS_HOST=$( [ "$ROLE" = "ctl" ] && echo 127.0.0.1 || echo "$CTL_LAN_IP" )
export REDIS_PORT=${REDIS_PORT}
export REDIS_DB=${REDIS_DB}
export REDIS_PASS=${REDIS_PASS}
export SIM_DATA_DIR=${SIMDATA}
export SIM_HOSTS=${SIM_HOSTS}
export SIM_NODES=${SIM_NODES}
ENV
$SUDO chmod 0644 "$STATE/sim-env.sh"

echo "=== bootstrap done role=$ROLE fail=$fail at $(date -Is) ==="
if [ "$fail" -ne 0 ]; then
    echo "One or more steps failed above. The node is up; the runtime may be"
    echo "incomplete. Run 'bash $REPO/cloudlab/verify-sim.sh' to see which."
fi
exit 0
