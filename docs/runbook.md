# Runbook

## 0. Before anything: the connection rules

`/Volumes/devessential/CLAUDE.md` rules **T1–T5** outrank every step here.
CloudLab's platform manager traced the repeated blocks of this project's IP to
**short logins to multiple nodes**, not to portal activity. In brief:

* **T1** A new allocation means a **new host list**, read from the notice.
  Never reuse the old one — machines recycle into different roles.
* **T2** The account is **`robin98`**, never the local `rin`. Never a bare
  `ssh <host>`.
* **T3** **Contact `ctl1` and nothing else.** Every other node is reached
  *from* `ctl1`, over the experiment LAN. This includes status checks.
* **T4** **Long-lived links only** — `ControlMaster auto`,
  `ControlPersist 30m`. Never open-and-close, never a per-node loop.
* **T5** **One transfer leaves the laptop.** Bulk data goes to `ctl1`, and
  `ctl1` fans it out. `make-sim-config.sh --distribute` follows this.

Load the `cloudlab-ssh` skill before the first connection and `cloudlab-ops`
before instantiating.

## 1. Allocate

★ **The portal boots a commit, not your working tree.** It instantiates what
is pushed to the git remote and selected in the portal. An unpushed local
edit silently does nothing and you will spend the afternoon debugging the old
profile. **Push, then check which commit the portal shows.**

| Preset | Machines | `num_wk_hosts` | Use |
|---|---|---|---|
| `single` | 1 | 0 | `ctl1` alone — the shape every run so far has used |
| `pair` | 2 | 1 | verify the multi-machine path works at all |
| `quad` | 4 | 3 | the usual way to shorten a long run |
| `large` | 8 | 7 | full spread |
| `custom` | — | — | the individual fields apply |

A preset overrides **only** `num_wk_hosts`. Hardware types, the per-slot
`wk<j>_hw_type` fields, `disk_image`, `sim_nodes` and `pypy_version` always
come from the form.

### Hardware

`hw_type` is **blank by default**, which is how an allocation succeeds on a
busy cluster. Pin a type to make a series of runs comparable.

★ **Verify cores and RAM on the cluster's hardware page before pinning.** A
type being listed as free is not the same as this project being allowed to
map it, and that only shows up when you attempt the map. Do not carry a core
count over from another allocation — `c220g1` was measured at 32 logical cpus
(2 sockets × 8 cores × 2 threads) on `robin98-316813`, and its RAM was *not*
verified there.

For a mixed allocation, fill the per-slot fields one at a time — that is
exactly the "the type I wanted ran out, take three of something else"
workflow — and read the `lan_best_effort` warning in the README first.

### For reported results

Bind the portal profile to a **release tag** of this repository rather than
to `main`, so the configuration cannot drift after the fact.

## 2. Verify the nodes

On `ctl1` (and, over the LAN from `ctl1`, on any node you suspect):

```bash
bash /local/repository/cloudlab/verify-sim.sh
```

| Check | Meaning | If it fails |
|---|---|---|
| S01 | PyPy present and is PyPy | see `/local/testbed/logs/bootstrap.log` |
| S02 | `sortedcontainers`, `redis`, `numpy` import | re-run the simulator's `setup_sim_environment.sh` |
| S03 | hard `nofile` ≥ 131072 | **reconnect first** — a login shell picks up new limits only on a fresh login |
| S04 | `/mnt/simdata` on its own disk | some types have only a root disk; collect results sooner |
| S04b | that disk is not LVM-striped | if it is, `sudo lvs -o +stripes,devices` before trusting any timing |
| S05 | Redis answers | on `ctl1`: `systemctl status redis-server` |
| S06 | this node registered under its own `$HOSTNAME` | `cloudlab/register-sim-node.sh` |
| S07 | chrony tracking | multi-machine timestamps will not correlate |
| S08 | all allocated machines registered | wait, or register the stragglers — **do not** generate the config yet |
| S09 | Redis listens **only** on loopback + `10.10.1.x` | a public-interface listener is a live exposure — fix `bind` in `/etc/redis/redis-simulator.conf` and restart |

Every check says **MISSING** (the thing is not there) or **WRONG** (it is
there and it is not right). They are different problems with different fixes.

Boot order is not ordered: a worker that came up before `ctl1`'s Redis waits
15 minutes, then gives up and leaves its facts in
`/local/testbed/sim-node-facts`. That is S06's normal cause, and
`register-sim-node.sh` is the whole fix.

## 3. Generate the simulator's cluster config

On `ctl1`, once S08 passes:

```bash
bash /local/repository/cloudlab/make-sim-config.sh --install --distribute
```

It prints the apportionment before writing anything:

```
20 simulated nodes over 4 machine(s), by core count:
  ctl1         master,worker  cpus=32   nodes=7   workers=7   worker_start=0   node_start=0
  wk1          worker         cpus=32   nodes=7   workers=7   worker_start=7   node_start=7
  wk2          worker         cpus=16   nodes=3   workers=3   worker_start=14  node_start=14
  wk3          worker         cpus=16   nodes=3   workers=3   worker_start=17  node_start=17
total simulated nodes: 20 (must be 20)
```

`--install` writes `mod_op.config` into
`~/consolidated-dc-simulator/tests/distributed/` on `ctl1`; `--distribute`
also sends it to every other registered node **over the experiment LAN**
(rule T5). Without `--install` it only writes `/local/testbed/mod_op.config`
and prints the copy command.

★ **The registry lives in Redis db 6, not db 5.** db 5 is the simulator's,
and its own `mod_op.sh clean` calls `flushdb()` on it
(`coordinator/messenger_redis.py:59`) — while the simulator's `CLAUDE.md`
requires cleaning **twice before every run**. Registering the cluster
description there meant mandatory housekeeping destroyed it; on
`robin98-317038` the registrations had to be backed up by hand before the
first clean. db 6 holds what describes the **testbed** and nothing the
simulator touches. If you are on an allocation that booted a profile from
before this change, re-run `register-sim-node.sh` on each node once so the
facts land in db 6.

Run it **again** whenever the machine set changes. It is keyed on each node's
own `$HOSTNAME`, which is what `mod_op.sh` indexes `arr_host_role` by — a
short name in one place and an FQDN in the other is precisely how a config
silently matches no host and a worker quietly does nothing.

## 4. Sync the simulator

From the laptop, to **`ctl1` only**:

```bash
cd /Volumes/devessential/aces
./consolidated-dc-simulator/tests/sync.sh ./consolidated-dc-simulator <ctl1-host>
```

For a multi-machine testbed, fan out from `ctl1` (T5) rather than syncing
each node from the laptop:

```bash
# on ctl1
rsync -a ~/consolidated-dc-simulator/ 10.10.1.21:~/consolidated-dc-simulator/
```

Then re-run `make-sim-config.sh --install --distribute`, because `--install`
needs `tests/distributed/` to exist before it can put the config there.

## 5. Run

On `ctl1`:

```bash
source /local/testbed/sim-env.sh          # SIM_PYTHON, REDIS_*, SIM_DATA_DIR
cd ~/consolidated-dc-simulator/tests/distributed
REDIS_PASS=1qaz2wsx ./mod_op.sh clean
REDIS_PASS=1qaz2wsx ./mod_op.sh clean     # twice, every time, before every run
pgrep -af 'run_cloudbank_20x14.sh|run_with_high_ulimit.sh|batch.sh|test.sh run_until|master.py --cmd start|worker.py --start'
```

The `pgrep` must print nothing. Then launch per the simulator's own
`CLAUDE.md` §3 — that file, not this one, is the authority on run parameters.

On a multi-machine testbed, `mod_op.sh` must be started on **each** node; it
reads `mod_op.config`, finds its own `$HOSTNAME`, and takes only the workers
and node indices assigned to it. Drive the other nodes from `ctl1`, never
from the laptop.

## 6. Collect

★ **`/mnt/simdata` is per-node.** There is no shared filesystem — not here,
not on AWS. Results written on `wk2` exist only on `wk2`. Pull them to `ctl1`
first, then take one transfer from `ctl1` to the laptop.

## 7. Things that have bitten this project

- **The portal boots a commit.** Push before instantiating. (§1)
- **Unpinned components drift and the symptom is never the cause.** The worst
  hunt here was a containerd TOML quote-style change that made a `sed`
  silently no-op. PyPy is pinned in `profile.py`; the three Python packages
  are not yet — `/local/testbed/sim-python-freeze.txt` records what a node
  actually resolved, which is what to copy from when a campaign needs pinning.
- **Golden images carry stale LVM.** `/mnt/simdata` would refuse to mount on
  different hardware — exactly what a heterogeneous allocation hands it. This
  profile uses the stock image plus a bootstrap script, deliberately.
- **A blockstore stripes across every device the node has.** On mixed flash,
  half of every `fsync` lands on the slow one; it looks fine in `df` and
  appears in no chart. No blockstore is declared here. If you add one, check
  `lvs -o +stripes,devices` on the live node — there is no profile parameter
  that pins it to a device.
- **Mixed NIC speeds fail *after* every node reaches ready.** See
  `lan_best_effort`. (§1)
- **Absent is not broken.** Every check here distinguishes the two. Three
  separate checks in one week reported a verdict about the code when the
  truth was a missing input.
- **The portal parses `profile.py` with PYTHON 2, in a jail.** A single
  non-ASCII byte fails the whole instantiation before any node is touched:
  `SyntaxError: Non-ASCII character '\xe2' ... but no encoding declared`,
  and the line number it reports is off by one from the real file. Three `*`
  characters used as emphasis markers cost a round-trip here. `profile.py`
  carries a PEP 263 line as a net, but keep the source ASCII regardless — and
  note that the reference profile that does boot,
  `cloudlab-cluster-macaw/profile.py`, is 100% ASCII. Python 2 also rules out
  f-strings, `print()` as a function with multiple arguments, and true
  division; test with `python2 -m py_compile profile.py` before pushing.
- **A CloudLab node's control interface is publicly routable.** `ctl1` was
  `128.105.145.221` on a recent allocation. Anything bound to `0.0.0.0` is
  published to the internet, and open Redis is scanned for continuously. The
  bootstrap binds Redis to loopback plus **this node's own** `10.10.1.x`
  address and nothing else; **S09** checks it rather than trusting it. Whether
  the site firewall happens to block 6379 is not the standard to design to —
  the cost of binding explicitly is zero, and the cost of being wrong lands on
  the account and the IP that T1–T5 exist to protect.
