#!/usr/bin/env bash
# Generate mod_op.config for the simulator from what the machines reported.
# Runs on ctl1.
#
#   bash make-sim-config.sh [--sim-nodes N] [--expect N]
#                           [--install] [--distribute]
#
# Reads every simnodes:* hash each node wrote about ITSELF at boot -- its own
# $HOSTNAME, its own LAN address, its own core count -- and apportions the
# simulated nodes across them IN PROPORTION TO CORES. That is what makes a
# heterogeneous allocation work without anyone declaring how big anything is:
# a 40-core machine takes twice the share of a 20-core one, and a machine
# nobody predicted takes whatever its cores are worth.
#
#   --install     also write it to ~/consolidated-dc-simulator/tests/
#                 distributed/mod_op.config on THIS node
#   --distribute  and send it to every other registered node over the
#                 experiment LAN (rule T5: the bytes leave the laptop once,
#                 the allocation fans them out)
#
# It reports "k of N registered" and refuses to guess. A config emitted for
# whoever happened to be up is the kind of silent half-truth that produces a
# run nobody can explain.
set -uo pipefail

STATE=/local/testbed
SIM_ENV="$STATE/sim-env.sh"
# shellcheck disable=SC1090
[ -f "$SIM_ENV" ] && . "$SIM_ENV"

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_DB="${REDIS_DB:-5}"
REDIS_PASS="${REDIS_PASS:-1qaz2wsx}"
SIM_NODES="${SIM_NODES:-20}"
EXPECT="${SIM_HOSTS:-0}"
INSTALL=0; DISTRIBUTE=0
OUT="$STATE/mod_op.config"
SIM_DIR="${SIM_DIR:-$HOME/consolidated-dc-simulator/tests/distributed}"

while [ $# -gt 0 ]; do
    case "$1" in
        --sim-nodes)  SIM_NODES="$2"; shift 2 ;;
        --expect)     EXPECT="$2";    shift 2 ;;
        --out)        OUT="$2";       shift 2 ;;
        --install)    INSTALL=1;      shift   ;;
        --distribute) DISTRIBUTE=1; INSTALL=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

rcli() { redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASS" -n "$REDIS_DB" "$@" 2>/dev/null; }

if ! rcli ping | grep -q PONG; then
    echo "MISSING: no Redis answering at $REDIS_HOST:$REDIS_PORT."
    echo "         This script runs on ctl1. On ctl1: systemctl status redis-server"
    exit 1
fi

keys="$(rcli --scan --pattern 'simnodes:*' | sort)"
if [ -z "$keys" ]; then
    echo "MISSING: Redis is up but no node has registered."
    echo "         Not a bug in this script. On each node:"
    echo "           bash /local/repository/cloudlab/register-sim-node.sh"
    exit 1
fi

facts=""
while read -r k; do
    [ -z "$k" ] && continue
    h="$(rcli hget "$k" hostname)"
    r="$(rcli hget "$k" role)"
    c="$(rcli hget "$k" cpus)"
    i="$(rcli hget "$k" lan_ip)"
    m="$(rcli hget "$k" mem_kb)"
    facts="${facts}${h}|${r}|${c}|${i}|${m}"$'\n'
done <<< "$keys"

registered="$(printf '%s' "$facts" | grep -c . || true)"
echo "registered: $registered node(s)"
if [ "$EXPECT" -gt 0 ] && [ "$registered" -ne "$EXPECT" ]; then
    echo
    echo "WARNING: the profile asked for $EXPECT machine(s) and $registered"
    echo "         registered. This is a MISSING node, not a broken config."
    echo "         Either wait for it and re-run, or run register-sim-node.sh"
    echo "         on it. Proceeding would silently size the run for fewer"
    echo "         machines than you allocated."
    echo
    read -r -p "Generate anyway for the $registered that registered? [y/N] " a
    case "$a" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

printf '%s' "$facts" | python3 - "$SIM_NODES" "$OUT" "$REDIS_HOST" \
        "$REDIS_PORT" "$REDIS_PASS" "$REDIS_DB" <<'PY'
import sys

sim_nodes = int(sys.argv[1]); out = sys.argv[2]
redis_host, redis_port, redis_pass, redis_db = sys.argv[3:7]

hosts = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    name, role, cpus, lan_ip, mem_kb = (line.split("|") + [""] * 5)[:5]
    hosts.append(dict(name=name, role=role, cpus=max(1, int(cpus or 1)),
                      lan_ip=lan_ip, mem_kb=int(mem_kb or 0)))

# ctl1 first and master; the rest by name, so the same allocation always
# produces the same config and two generations can be diffed.
hosts.sort(key=lambda h: (h["role"] != "ctl", h["name"]))
if not any(h["role"] == "ctl" for h in hosts):
    sys.exit("MISSING: no node registered with role=ctl. The master has to "
             "be ctl1; nothing here can substitute for it.")

# More machines than simulated nodes: the extra machines get nothing rather
# than a fractional share. Said out loud, because an idle machine you paid
# for looks identical to a machine that failed.
if len(hosts) > sim_nodes:
    # ctl1 is kept unconditionally, however small it is: it runs the master
    # and Redis, so a config without it is not a smaller run, it is no run.
    ctl_hosts = [h for h in hosts if h["role"] == "ctl"]
    others = sorted((h for h in hosts if h["role"] != "ctl"),
                    key=lambda h: (-h["cpus"], h["name"]))
    keep = ctl_hosts + others[:max(0, sim_nodes - len(ctl_hosts))]
    dropped = others[max(0, sim_nodes - len(ctl_hosts)):]
    hosts = sorted(keep, key=lambda h: (h["role"] != "ctl", h["name"]))
    print("NOTE: %d simulated nodes over %d machines -- these take no share: %s"
          % (sim_nodes, len(keep) + len(dropped),
             ", ".join(h["name"] for h in dropped)))

# Largest-remainder apportionment by cores, with a floor of one node per
# machine so no allocated machine sits idle.
total_cpus = sum(h["cpus"] for h in hosts)
exact = [sim_nodes * h["cpus"] / float(total_cpus) for h in hosts]
share = [max(1, int(e)) for e in exact]
while sum(share) > sim_nodes:            # the floor overshot: trim the richest
    i = max(range(len(share)), key=lambda k: (share[k], -exact[k]))
    if share[i] > 1:
        share[i] -= 1
    else:
        break
remainders = sorted(range(len(hosts)), key=lambda k: -(exact[k] - int(exact[k])))
k = 0
while sum(share) < sim_nodes:
    share[remainders[k % len(remainders)]] += 1
    k += 1

# One worker process per simulated node, which is what the 32c-252g profile
# does (20 workers x 1 node). Keeping nodes_per_worker at 1 makes
# node_start_index = worker_start_index and the totals exact by construction.
lines, worker_idx, node_idx, report = [], 0, 0, []
for h, n in zip(hosts, share):
    role = "master,worker" if h["role"] == "ctl" else "worker"
    lines.append((h["name"], role, n, 1, worker_idx, node_idx))
    report.append("  %-12s %-14s cpus=%-4d nodes=%-3d workers=%-3d "
                  "worker_start=%-3d node_start=%d"
                  % (h["name"], role, h["cpus"], n, n, worker_idx, node_idx))
    worker_idx += n
    node_idx += n

ctl = [h for h in hosts if h["role"] == "ctl"][0]
redis_target = ctl["lan_ip"] if (len(hosts) > 1 and ctl["lan_ip"] not in ("", "none")) else "127.0.0.1"

body = []
body.append("# Generated by cloudlab/make-sim-config.sh from what each node")
body.append("# reported about itself. Do not hand-edit: regenerate.")
body.append("# in bash format")
body.append("")
body.append("redis_host=%s" % redis_target)
body.append("redis_port=%s" % redis_port)
body.append("redis_pass=%s" % redis_pass)
body.append("redis_db=%s" % redis_db)
body.append('broadcast_channel="broadcast#cds_test"')
body.append("")
body.append("parallel_degree_for_preprocessing=%d" % min(32, ctl["cpus"]))
body.append("parallel_degree_for_aggregating=1")
body.append("")
for decl in ("arr_host_role", "arr_parallel_workers", "arr_nodes_per_worker",
             "arr_worker_start_index", "arr_node_start_index"):
    body.append("declare -A %s" % decl)
body.append("")
for name, role, n, npw, wstart, nstart in lines:
    body.append("arr_host_role[%s]=%s" % (name, role))
body.append("")
for name, role, n, npw, wstart, nstart in lines:
    body.append("arr_parallel_workers[%s]=%d" % (name, n))
    body.append("arr_nodes_per_worker[%s]=%d" % (name, npw))
    body.append("arr_worker_start_index[%s]=%d" % (name, wstart))
    body.append("arr_node_start_index[%s]=%d" % (name, nstart))
    body.append("")

with open(out, "w") as fh:
    fh.write("\n".join(body).rstrip() + "\n")

print("")
print("%d simulated nodes over %d machine(s), by core count:" % (sim_nodes, len(hosts)))
print("\n".join(report))
print("")
print("total simulated nodes: %d (must be %d)" % (node_idx, sim_nodes))
print("redis_host in the config: %s" % redis_target)
print("written: %s" % out)
PY
rc=$?
[ "$rc" -ne 0 ] && { echo "config generation failed"; exit "$rc"; }

# ---- install on this node ---------------------------------------------------
if [ "$INSTALL" -eq 1 ]; then
    if [ -d "$SIM_DIR" ]; then
        cp "$OUT" "$SIM_DIR/mod_op.config"
        echo "installed: $SIM_DIR/mod_op.config"
    else
        echo "MISSING: $SIM_DIR does not exist yet -- the simulator has not"
        echo "         been synced to this node. Not an error in the config."
        echo "         After tests/sync.sh, copy it:"
        echo "           cp $OUT $SIM_DIR/mod_op.config"
    fi
fi

# ---- fan out from here, never from the laptop (rule T5) ---------------------
if [ "$DISTRIBUTE" -eq 1 ]; then
    echo
    while read -r line; do
        [ -z "$line" ] && continue
        h="${line%%|*}"; rest="${line#*|}"; role="${rest%%|*}"
        rest="${rest#*|}"; rest="${rest#*|}"; ip="${rest%%|*}"
        [ "$role" = "ctl" ] && continue
        if [ "$ip" = "none" ] || [ -z "$ip" ]; then
            echo "MISSING: $h has no experiment-LAN address; skipped."
            continue
        fi
        if rsync -q "$OUT" "$ip:$SIM_DIR/mod_op.config" 2>/dev/null; then
            echo "sent to $h ($ip)"
        else
            echo "WRONG or MISSING on $h ($ip): rsync failed. Either"
            echo "      $SIM_DIR does not exist there yet (sync the simulator"
            echo "      first) or ssh from ctl1 to it is not set up."
        fi
    done <<< "$facts"
fi
