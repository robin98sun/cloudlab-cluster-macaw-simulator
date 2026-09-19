# cloudlab-cluster-macaw-simulator

A CloudLab profile for the **consolidated DC simulator** — N bare-metal
machines, N ≥ 1, deliberately **heterogeneous**, plus the bootstrap and
config-generation tooling that turns whatever you were allocated into a
simulator cluster.

The simulator does not care how big any single machine is. It spreads a
fixed number of **simulated** nodes (20, the CloudBank 20x14 topology) across
however many **real** machines exist, in proportion to each machine's core
count. So "the type I wanted was short, take three of something else" is a
normal allocation here, not a degraded one — and the only thing more machines
buy is a shorter wall clock for the same experiment.

| Role | Hosts | Purpose |
|---|---|---|
| `ctl1` | always | Redis coordination bus, simulator **master**, and a worker like any other. With N=1 it is the whole testbed. |
| `wk<j>` | optional | additional worker machines, each of which **may be a different CloudLab hardware type** |

`ctl1` is named `ctl1` on purpose: every piece of ssh tooling in these
projects assumes the one contactable host is called that, and rule **T3**
says exactly one host is contacted from the laptop. Don't rename it, not even
when N=1.

## What the profile installs

The **runtime only** — it does not install the simulator.

- **PyPy**, pinned (`pypy3.10-v7.3.17-linux64`), at `/usr/local/bin/pypy3`
- `sortedcontainers`, `redis`, `numpy`, with resolved versions recorded to
  `/local/testbed/sim-python-freeze.txt`
- **Redis** on `ctl1` only, configured through a drop-in (never a `sed`
  against generated config)
- a raised **file-descriptor limit**, for both login shells and systemd units
- a data filesystem at **`/mnt/simdata`** on the node's largest spare disk
- `chrony`, so timestamps across machines correlate

The simulator itself arrives afterwards over rsync from the laptop
(`consolidated-dc-simulator/tests/sync.sh`). The authority on the Python
environment stays the simulator's own
`tests/distributed/setup_sim_environment.sh`; this profile mirrors its pinned
versions so a node is usable before the first sync, and that script is
idempotent and can always be re-run.

> **`/mnt/simdata`, never `/mnt/shared-storage`.** Nothing here is shared
> between nodes — each mounts its own local disk. The other name asserts a
> property that path has never had, on CloudLab or on AWS, and it has already
> cost this project days. Results are per-node and must be collected per-node.

## Heterogeneity: two fields, one rule

```
num_wk_hosts = 3          ->  wk1 wk2 wk3, all of hw_type
wk2_hw_type  = c220g5     ->  wk2 is a c220g5 instead
wk7_hw_type  = d430       ->  wk7 exists as well, as a d430
```

A slot exists if its number is ≤ `num_wk_hosts` **or** its own type field is
filled. Its type is its own field, else `hw_type_wk`, else `hw_type`. Slots
are addressed **by slot number** — `wk3` is always `10.10.1.23` whether or not
`wk2` was ever requested — so a host already named in a generated config never
changes address because another was added later.

> ⚠ **Mixed interface speeds break the LAN.** Emulab refuses to build one flat
> LAN across hardware types whose NICs differ: an 11×`d430` + 3×`d710` request
> mapped every node and *then* failed at `SliverStart: Failed to set up
> experimental networks`. Turn on `lan_best_effort` to build such a LAN at
> all — and read what it costs first. It buys a testbed that works, never one
> comparable to the others.

## How the cluster describes itself

Nothing in the profile declares how big any machine is. At boot **each node
registers its own facts** — the exact `$HOSTNAME` the simulator will key on,
its LAN address, and its real core count — into Redis on `ctl1`. Then, on
`ctl1`:

```bash
bash /local/repository/cloudlab/make-sim-config.sh --install --distribute
```

reads them back, apportions the 20 simulated nodes by core count, and emits
`mod_op.config` in exactly the format `mod_op.sh` sources — `arr_host_role`,
`arr_parallel_workers`, `arr_nodes_per_worker`, `arr_worker_start_index`,
`arr_node_start_index`. It reports "k of N registered" and refuses to guess:
a config quietly emitted for whoever happened to be up is the kind of
half-truth that produces a run nobody can explain.

```
profile.py                       CloudLab geni-lib profile (presets: single/pair/quad/large)
cloudlab/bootstrap.sh            per-node runtime bootstrap, runs at every boot
cloudlab/register-sim-node.sh    re-register a node that booted before ctl1
cloudlab/make-sim-config.sh      generate + distribute mod_op.config from what nodes reported
cloudlab/verify-sim.sh           per-node check suite (MISSING vs WRONG)
docs/runbook.md                  allocate, verify, sync, run, collect
```

## Quick start

1. **Push first.** The portal instantiates the commit on the git remote, not
   your working tree.
2. Create a profile in the CloudLab portal from this repository, then
   instantiate it — preset `single` for one machine.
3. Connect to `ctl1` **and only `ctl1`** (rules T1–T4), then:

```bash
bash /local/repository/cloudlab/verify-sim.sh
```

See [docs/runbook.md](docs/runbook.md) for the rest.

## License

MIT. See [LICENSE](LICENSE).
