"""Consolidated DC simulator testbed on CloudLab bare metal.

N machines, N >= 1, DELIBERATELY HETEROGENEOUS. The simulator does not care
how big any single machine is: it spreads a fixed number of SIMULATED nodes
(20 for CloudBank 20x14) across whatever real machines it is given, in
proportion to each machine's core count. So a slow machine is not a problem
to be avoided, only a smaller share to be measured -- and "the type I wanted
was short, take three of something else" is a normal allocation, not a
degraded one.

    ctl1    always present. Redis coordination bus, simulator MASTER, and a
            worker like any other. With N=1 it is the whole testbed.
    wk<j>   additional worker machines. Each may be a DIFFERENT CloudLab
            hardware type -- see the per-slot fields below.

★ ctl1 is named ctl1 on purpose. Every piece of ssh tooling in these
  projects assumes the one contactable host is called that, and rule T3
  (/Volumes/devessential/CLAUDE.md) says exactly one host is contacted from
  the laptop and every other node is reached from inside the allocation.
  ctl1 is that host. Do not rename it, not even when N=1.

HETEROGENEITY, two ways, one rule:

    num_wk_hosts = 3                 -> wk1 wk2 wk3, all of hw_type
    wk2_hw_type  = "c220g5"          -> wk2 is a c220g5 instead
    wk7_hw_type  = "d430"            -> wk7 exists as well, as a d430

  A slot exists if its number is <= num_wk_hosts OR its own type field is
  filled. A slot's type is its own field, else hw_type_wk, else hw_type.
  Slots are addressed BY SLOT NUMBER: wk3 is 10.10.1.23 whether or not wk2
  was ever requested, so a host that was already named in a config never
  changes address because another was added later.

★ MIXED INTERFACE SPEEDS BREAK THE LAN. Emulab refuses to build one flat
  LAN across hardware types whose NICs differ (1Gb d710 + 10Gb d430 mapped
  fine and then failed at 'SliverStart: Failed to set up experimental
  networks'). Turn on lan_best_effort to build such a LAN at all. Read that
  parameter's description first: it buys a testbed that works, never one
  that is comparable to the others.

WHAT RUNS HERE. cloudlab/bootstrap.sh installs the runtime the simulator
needs and nothing else -- PyPy (pinned), its three packages, Redis on ctl1,
a raised file-descriptor limit, and a data filesystem. It does NOT install
the simulator: that arrives later over rsync from the laptop
(consolidated-dc-simulator/tests/sync.sh). The authority on the Python
environment remains the simulator's own tests/distributed/
setup_sim_environment.sh; this profile mirrors its pinned versions so a
fresh node is usable before the first sync, and that script can always be
re-run afterwards.

★ THE DATA FILESYSTEM IS CALLED /mnt/simdata, NOT /mnt/shared-storage.
  Nothing here is shared between nodes. The name /mnt/shared-storage asserts
  a property that path has never had on CloudLab or AWS -- every node mounts
  its own local disk there -- and it has already cost this project days.
  Results are per-node and must be collected per-node.

Network: one experiment LAN, 10.10.1.0/24, built only when there are at
least two machines. Redis listens on ctl1's LAN address. Control traffic
(your ssh, the portal) rides CloudLab's control network, so the experiment
LAN stays clean.

    ctl1  10.10.1.10        wk<j>  10.10.1.(20+j)

Address plan and slot numbering are frozen: change them and every
mod_op.config already generated becomes wrong.
"""
import geni.portal as portal
import geni.rspec.pg as pg

# Stock image plus a bootstrap script, deliberately. A golden image carries
# stale LVM metadata that refuses to mount on different hardware -- which is
# exactly what a heterogeneous allocation hands it.
BASE_IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"

# Pinned so an allocation is reproducible from a commit alone. Mirrors
# consolidated-dc-simulator/tests/distributed/setup_sim_environment.sh.
DEFAULT_PYPY = "pypy3.10-v7.3.17-linux64"

# Simulated nodes in the CloudBank 20x14 topology. This is a property of the
# workload, not of the allocation: the same 20 are spread over however many
# machines exist.
DEFAULT_SIM_NODES = 20

# Highest wk slot the address plan has room for: 10.10.1.21 .. 10.10.1.35.
MAX_WK_SLOTS = 15

PRESETS = {
    # name          extra machines beyond ctl1
    "single":     dict(num_wk_hosts=0),
    "pair":       dict(num_wk_hosts=1),
    "quad":       dict(num_wk_hosts=3),
    "large":      dict(num_wk_hosts=7),
}

pc = portal.Context()

pc.defineParameter(
    "preset", "Configuration preset", portal.ParameterType.STRING, "custom",
    longDescription="Free text, and 'custom' by default, which leaves every "
                    "field below in force. Naming a preset -- single, pair, "
                    "quad, large -- OVERRIDES only num_wk_hosts; hardware "
                    "types, the per-slot fields, disk_image and sim_nodes "
                    "always come from the form. Machines = 1 + num_wk_hosts, "
                    "plus any extra slot given its own type.")
pc.defineParameter(
    "num_wk_hosts", "Additional worker machines (beyond ctl1)",
    portal.ParameterType.INTEGER, 0,
    longDescription="0 gives a single-machine testbed: ctl1 alone, which is "
                    "the shape every run so far has used. Raising this "
                    "spreads the same sim_nodes simulated nodes over more "
                    "machines, which is the only thing that shortens a long "
                    "run. Slots given their own type below exist regardless "
                    "of this count.")
pc.defineParameter(
    "hw_type", "Hardware type (cluster-wide default)",
    portal.ParameterType.STRING, "",
    longDescription="Blank lets CloudLab choose, which on a busy cluster is "
                    "how an allocation succeeds at all. Pin one to make a "
                    "series of runs comparable. VERIFY CORES AND RAM ON THE "
                    "CLUSTER'S HARDWARE PAGE BEFORE PINNING -- a type being "
                    "listed as free is not the same as this project being "
                    "allowed to map it, and that only shows up when you try.")
pc.defineParameter(
    "hw_type_ctl", "Hardware type for ctl1", portal.ParameterType.STRING, "",
    advanced=True,
    longDescription="Overrides hw_type for ctl1 only. ctl1 additionally runs "
                    "Redis and the master, so give it the larger type when "
                    "the allocation is mixed.")
pc.defineParameter(
    "hw_type_wk", "Hardware type for wk hosts", portal.ParameterType.STRING,
    "", advanced=True,
    longDescription="Overrides hw_type for every wk slot that does not name "
                    "its own type.")
for _j in range(1, MAX_WK_SLOTS + 1):
    pc.defineParameter(
        "wk%d_hw_type" % _j, "wk%d: hardware type" % _j,
        portal.ParameterType.STRING, "", advanced=True,
        longDescription="One machine of this CloudLab type, named wk%d, at "
                        "10.10.1.%d. Filling this creates the slot even when "
                        "num_wk_hosts is smaller, which is how a mixed "
                        "allocation is assembled one type at a time. Empty "
                        "leaves the slot to num_wk_hosts."
                        % (_j, 20 + _j))
pc.defineParameter(
    "sim_nodes", "Simulated nodes to spread over the machines",
    portal.ParameterType.INTEGER, DEFAULT_SIM_NODES,
    longDescription="20 is the CloudBank 20x14 topology and should not be "
                    "changed to fit an allocation -- changing it changes the "
                    "experiment. It is passed to ctl1 so make-sim-config.sh "
                    "knows the total to divide.")
pc.defineParameter(
    "disk_image", "Disk image URN", portal.ParameterType.STRING, BASE_IMAGE,
    advanced=True,
    longDescription="Stock Ubuntu 22.04. Not overridden by presets. A golden "
                    "image is deliberately NOT used: its baked LVM metadata "
                    "refuses to mount on hardware other than the machine it "
                    "was captured on, and this profile expects mixed types.")
pc.defineParameter(
    "pypy_version", "PyPy version", portal.ParameterType.STRING, DEFAULT_PYPY,
    advanced=True,
    longDescription="Installed from the official tarball into ~/opt with a "
                    "~/bin/pypy3 symlink, matching the simulator's own "
                    "setup_sim_environment.sh. Pinned on purpose: an "
                    "unpinned runtime that moves mid-campaign changes the "
                    "numbers and the symptom never points at the cause.")
pc.defineParameter(
    "link_bw", "Experiment LAN bandwidth (Kbps, 0 = native)",
    portal.ParameterType.INTEGER, 0, advanced=True,
    longDescription="0 leaves the link at line rate. The simulator's Redis "
                    "traffic is small; shape this only to model a "
                    "constrained network deliberately.")
pc.defineParameter(
    "lan_best_effort", "Best-effort experiment LAN (mixed hardware only)",
    portal.ParameterType.BOOLEAN, False, advanced=True,
    longDescription="Leave OFF for anything that produces a number. Emulab "
                    "refuses to build one flat LAN across hardware types "
                    "with different interface speeds: a 11x d430 + 3x d710 "
                    "map reached ready on every node and then failed with "
                    "'SliverStart: Failed to set up experimental networks' "
                    "(robin98-315025, 2026-09-08). This drops the bandwidth "
                    "guarantee so such a LAN builds at all -- which is what "
                    "makes 'add a few of another type to reach the count' "
                    "possible when the preferred type is short. It buys a "
                    "testbed that works, never a comparable one.")

params = pc.bindParameters()

cfg = {f: getattr(params, f) for f in
       ("num_wk_hosts", "hw_type", "sim_nodes", "disk_image",
        "pypy_version", "link_bw", "lan_best_effort")}
cfg["hw_type_ctl"] = params.hw_type_ctl.strip()
cfg["hw_type_wk"] = params.hw_type_wk.strip()
cfg["hw_type"] = cfg["hw_type"].strip()

if params.preset != "custom":
    if params.preset not in PRESETS:
        pc.reportError(portal.ParameterError(
            "unknown preset %r" % params.preset, ["preset"]))
    else:
        cfg.update(PRESETS[params.preset])

# Per-slot types are read AFTER the preset, so a preset sets the count and a
# slot field still wins over it.
slot_types = {_j: getattr(params, "wk%d_hw_type" % _j, "").strip()
              for _j in range(1, MAX_WK_SLOTS + 1)}

if cfg["num_wk_hosts"] < 0:
    pc.reportError(portal.ParameterError(
        "Additional worker machines cannot be negative. 0 is a valid, and "
        "the usual, testbed: ctl1 alone.", ["num_wk_hosts"]))
if cfg["num_wk_hosts"] > MAX_WK_SLOTS:
    pc.reportError(portal.ParameterError(
        "At most %d additional machines: the address plan gives wk slots "
        "10.10.1.21 upward and stops at 10.10.1.%d."
        % (MAX_WK_SLOTS, 20 + MAX_WK_SLOTS), ["num_wk_hosts"]))
if cfg["sim_nodes"] < 1:
    pc.reportError(portal.ParameterError(
        "At least one simulated node.", ["sim_nodes"]))
if not str(cfg["pypy_version"]).strip():
    pc.reportError(portal.ParameterError(
        "PyPy version must not be empty; it is pinned on purpose.",
        ["pypy_version"]))

# A slot exists if the count covers it or it named its own type. Gaps are
# fine and expected -- a type stops being available between one Modify and
# the next, so you fill wk4 while wk2 stays empty.
wk_slots = sorted({_j for _j in range(1, MAX_WK_SLOTS + 1)
                   if _j <= cfg["num_wk_hosts"] or slot_types[_j]})

# MIXED INTERFACE SPEEDS: deliberately NOT enforced here. Types can differ
# and still share a NIC speed, and only the mapper knows which. Refusing
# would block a legitimate allocation. The failure to recognise, should it
# come, is 'SliverStart: Failed to set up experimental networks' AFTER every
# node reaches ready -- turn lan_best_effort on and read what it costs.
# (geni-lib's warning API is not verifiable from here, so this stays a
# comment and a parameter description rather than a call that might not
# exist on the portal's version.)

pc.verifyParameters()

request = pc.makeRequestRSpec()

# One experiment LAN, and ONLY when there is something to connect. A LAN
# with a single interface is not a network, and a single-machine testbed is
# the common case here.
sim_lan = None
if wk_slots:
    sim_lan = request.LAN("sim")
    if cfg["link_bw"] > 0:
        sim_lan.bandwidth = cfg["link_bw"]
    if cfg["lan_best_effort"]:
        sim_lan.best_effort = True


def make_node(name, role, hw, extra_args=""):
    node = request.RawPC(name)
    if hw:
        node.hardware_type = hw
    node.disk_image = cfg["disk_image"]
    # The portal clones this repository to /local/repository on every node
    # before the service runs, so the script is already present at boot and
    # there is no network fetch to fail.
    node.addService(pg.Execute(
        shell="bash",
        command="bash /local/repository/cloudlab/bootstrap.sh %s "
                "--pypy-version %s%s"
                % (role, cfg["pypy_version"], extra_args)))
    return node


def attach(node, addr):
    if sim_lan is None:
        return
    iface = node.addInterface()
    iface.addAddress(pg.IPv4Address(addr, "255.255.255.0"))
    sim_lan.addInterface(iface)


# ctl1: Redis, the simulator master, and a worker like any other. It is told
# the full guest list so make-sim-config.sh can say "3 of 4 registered"
# rather than silently emitting a config for whoever happened to be up.
ctl = make_node("ctl1", "ctl", cfg["hw_type_ctl"] or cfg["hw_type"],
                " --sim-hosts %d --sim-nodes %d --wk-slots %s"
                % (1 + len(wk_slots), cfg["sim_nodes"],
                   ",".join(str(_j) for _j in wk_slots) or "none"))
attach(ctl, "10.10.1.10")

for _j in wk_slots:
    hw = slot_types[_j] or cfg["hw_type_wk"] or cfg["hw_type"]
    n = make_node("wk%d" % _j, "wk", hw)
    attach(n, "10.10.1.%d" % (20 + _j))

pc.printRequestRSpec(request)
