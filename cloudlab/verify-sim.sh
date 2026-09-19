#!/usr/bin/env bash
# Verify a simulator testbed node. Run on any node; run it on ctl1 for the
# cluster-wide checks too.
#
#   bash /local/repository/cloudlab/verify-sim.sh
#
# Every check says MISSING (the thing is not there) or WRONG (it is there and
# it is not right). They are different problems with different fixes, and
# collapsing them is how a verdict about the code gets reported when the
# truth was a missing input.
set -uo pipefail

STATE=/local/testbed
SIMDATA=/mnt/simdata
# shellcheck disable=SC1091
[ -f "$STATE/sim-env.sh" ] && . "$STATE/sim-env.sh"
SIM_PYTHON="${SIM_PYTHON:-/usr/local/bin/pypy3}"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_DB="${REDIS_DB:-5}"
REDIS_PASS="${REDIS_PASS:-1qaz2wsx}"

pass=0; warn=0; failed=0
ok()   { printf '  %-5s %-34s %s\n' "PASS" "$1" "$2"; pass=$((pass+1)); }
bad()  { printf '  %-5s %-34s %s\n' "FAIL" "$1" "$2"; failed=$((failed+1)); }
soft() { printf '  %-5s %-34s %s\n' "WARN" "$1" "$2"; warn=$((warn+1)); }

echo "simulator node check -- $(hostname) -- $(date -Is)"
echo

# S01 -----------------------------------------------------------------------
if [ ! -x "$SIM_PYTHON" ]; then
    bad S01-pypy "MISSING: $SIM_PYTHON is not there. See $STATE/logs/bootstrap.log"
else
    v="$("$SIM_PYTHON" --version 2>&1 | head -1)"
    case "$v" in
        *PyPy*) ok S01-pypy "$v" ;;
        *) bad S01-pypy "WRONG: $SIM_PYTHON exists but is not PyPy: $v" ;;
    esac
fi

# S02 -----------------------------------------------------------------------
if [ -x "$SIM_PYTHON" ]; then
    missing=""
    for m in sortedcontainers redis numpy; do
        "$SIM_PYTHON" -c "import $m" >/dev/null 2>&1 || missing="$missing $m"
    done
    if [ -z "$missing" ]; then
        ok S02-packages "sortedcontainers, redis, numpy import"
    else
        bad S02-packages "MISSING:${missing}. Re-run the simulator's own setup_sim_environment.sh"
    fi
else
    bad S02-packages "MISSING: no interpreter to import into (see S01)"
fi

# S03 -----------------------------------------------------------------------
# run_with_high_ulimit.sh raises the SOFT limit to the HARD one, so the hard
# limit is the one that has to be large.
hard="$(ulimit -Hn 2>/dev/null || echo 0)"
if [ "$hard" -ge 131072 ] 2>/dev/null; then
    ok S03-nofile "hard nofile = $hard"
elif [ "$hard" -gt 0 ]; then
    soft S03-nofile "WRONG: hard nofile = $hard, want >= 131072. A login shell picks the new limit up only on a FRESH login -- reconnect and re-check before treating this as real."
else
    bad S03-nofile "MISSING: could not read ulimit -Hn"
fi

# S04 -----------------------------------------------------------------------
if mountpoint -q "$SIMDATA" 2>/dev/null; then
    src="$(findmnt -no SOURCE "$SIMDATA")"
    avail="$(df -h --output=avail "$SIMDATA" 2>/dev/null | tail -1 | tr -d ' ')"
    ok S04-simdata "$src -> $SIMDATA, $avail free"
    # An LVM device here would mean a blockstore was added; on mixed flash
    # LVM stripes across every device and half of every fsync lands on the
    # slow one. It looks fine in df and appears in no chart.
    case "$src" in
        /dev/mapper/*|/dev/*vg*/*)
            soft S04b-lvm "$src is LVM: check 'sudo lvs -o +stripes,devices' before trusting any timing" ;;
    esac
else
    soft S04-simdata "MISSING: no separate disk; $SIMDATA is on the ~64 GB root filesystem. Collect results sooner."
fi

# S05 -----------------------------------------------------------------------
if ! command -v redis-cli >/dev/null 2>&1; then
    bad S05-redis "MISSING: redis-cli is not installed"
elif redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASS" -n "$REDIS_DB" ping 2>/dev/null | grep -q PONG; then
    ok S05-redis "PONG from $REDIS_HOST:$REDIS_PORT db $REDIS_DB"
else
    bad S05-redis "MISSING or WRONG: no PONG from $REDIS_HOST:$REDIS_PORT. On ctl1: systemctl status redis-server"
fi

# S06 -----------------------------------------------------------------------
# The simulator keys arr_host_role by $HOSTNAME. If this node registered
# under a different string than bash reports here, its config entry will
# match no host and it will silently do nothing.
me="$(hostname)"
reg="$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASS" -n "$REDIS_DB" hget "simnodes:$me" cpus 2>/dev/null)"
if [ -n "$reg" ]; then
    ok S06-registered "$me registered, cpus=$reg"
else
    bad S06-registered "MISSING: no simnodes:$me in Redis. Run cloudlab/register-sim-node.sh here."
fi

# S07 -----------------------------------------------------------------------
if command -v chronyc >/dev/null 2>&1 && chronyc tracking >/dev/null 2>&1; then
    ok S07-clock "chrony tracking"
else
    soft S07-clock "MISSING: chrony is not tracking. Multi-machine timestamps will not correlate."
fi

# S08 -----------------------------------------------------------------------
n="$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASS" -n "$REDIS_DB" --scan --pattern 'simnodes:*' 2>/dev/null | grep -c . || echo 0)"
want="${SIM_HOSTS:-0}"
if [ "$want" -gt 0 ] && [ "$n" -ne "$want" ]; then
    bad S08-quorum "MISSING: $n of $want machines registered. Do not generate mod_op.config yet."
elif [ "$n" -gt 0 ]; then
    ok S08-quorum "$n machine(s) registered${want:+ of $want}"
else
    bad S08-quorum "MISSING: nothing registered"
fi

echo
echo "  pass=$pass warn=$warn fail=$failed"
[ "$failed" -eq 0 ] || echo "  a FAIL above is the thing to fix before syncing the simulator."
exit 0
