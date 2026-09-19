#!/usr/bin/env bash
# Re-register this node with ctl1's Redis.
#
# bootstrap.sh does this at boot, but node boot order is not ordered: a
# worker that came up before ctl1's Redis waits 15 minutes and then gives
# up, leaving its facts in /local/testbed/sim-node-facts. Run this once ctl1
# is up. Idempotent -- registering twice is the same as registering once.
set -uo pipefail

STATE=/local/testbed
CTL_LAN_IP="${CTL_LAN_IP:-10.10.1.10}"
REDIS_PORT="${REDIS_PORT:-6379}"
# The registry db, NOT the simulator db -- mod_op.sh clean flushes that one.
REGISTRY_DB="${SIM_REGISTRY_DB:-6}"
REDIS_PASS="${REDIS_PASS:-1qaz2wsx}"

if [ ! -f "$STATE/sim-node-facts" ]; then
    echo "MISSING: $STATE/sim-node-facts does not exist."
    echo "         bootstrap.sh never got far enough to write it. Read"
    echo "         $STATE/logs/bootstrap.log before re-running this."
    exit 1
fi
# shellcheck disable=SC1091
. "$STATE/sim-node-facts"

target="$CTL_LAN_IP"
[ "${lan_ip:-none}" = "none" ] && target="127.0.0.1"

if ! redis-cli -h "$target" -p "$REDIS_PORT" -a "$REDIS_PASS" -n "$REGISTRY_DB" \
        ping 2>/dev/null | grep -q PONG; then
    echo "MISSING: no Redis answering at $target:$REDIS_PORT."
    echo "         On ctl1: systemctl status redis-server"
    exit 1
fi
redis-cli -h "$target" -p "$REDIS_PORT" -a "$REDIS_PASS" -n "$REGISTRY_DB" \
    hset "simnodes:$hostname" hostname "$hostname" role "$role" \
    lan_ip "$lan_ip" cpus "$cpus" mem_kb "$mem_kb" \
    registered_at "$(date -Is)" >/dev/null 2>&1 \
    || { echo "WRONG: Redis answered PING but refused the write."; exit 1; }
echo "registered $hostname (role=$role cpus=$cpus lan_ip=$lan_ip)"
