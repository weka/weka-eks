# NUMA-aware core/NIC pinning for the WEKA operator

Notes on whether and how the WEKA operator could support NUMA-aware
pairing of WEKA cores and DPDK NICs, with a focus on dual-socket
HyperPod GPU instances (`ml.p5.48xlarge`, `ml.p6.*`).

## Why this matters

On a dual-socket node, going through the QPI/UPI interconnect
between sockets to access a remote NIC is measurably slower:
roughly 10–20% throughput loss and higher tail latency at high IOPS.

For a bare-metal WEKA mount you control NUMA affinity directly via
the mount command's `cores=` and `net=` options — pick cores and a
NIC on the same socket and you're done.

In the operator-managed model that fine-grained control is hidden:
the operator exposes `coresNum` and an opaque NIC pool, and
allocates them with no socket awareness.

## Backends and Axon

The discussion above is client-focused (core-to-NIC pairing). For
**WEKA backends**, the same NUMA story applies plus a third
pairing — drives — because NVMe attaches over PCIe and each PCIe
slot is physically tied to one socket's IOHub.

Three NUMA pairings to worry about on a backend host:

| Pair | Why it matters |
| --- | --- |
| Drive core ↔ NVMe drive | Every NVMe I/O goes over PCIe. A drive process pinned to NUMA 0 reading an NVMe on NUMA 1 crosses QPI/UPI on every block request. Measurable latency and lower peak IOPS. |
| Drive core ↔ NIC | Drive processes send replicas to peer backends over the network. Cross-socket NIC access costs interconnect bandwidth on every egress. |
| Compute core ↔ NIC | Compute processes run data services (dedup, tiering) and inter-backend chatter. Same NIC affinity story as clients. |

On a bare-metal backend the canonical dual-socket layout is one
set of containers per socket:

- **Socket 0**: drive container pinned to NUMA-0 cores, owns the
  NVMe drives on NUMA-0's PCIe, uses NUMA-0 NICs.
- **Socket 1**: same layout on the other socket.

Done right, no I/O crosses QPI/UPI on the hot path.

### Axon

Axon converges backend + client on the same node, which amplifies
the problem. On a dual-socket node you're juggling:

- Drive processes wanting alignment with drives + NICs
- Compute processes wanting alignment with NICs
- Client frontend processes wanting alignment with NICs
- The application pod above the client, ideally aligned with its
  frontend so POSIX calls stay on one socket

On bare-metal Axon you'd carve each socket into a backend slice +
a client slice with reservations for the app. The operator today
treats the node as a flat pool for cores, NICs, and drives — no
NUMA awareness on any of the three.

### Drive NUMA metadata

Good news: drive NUMA is as easy to discover as NIC NUMA:

```text
/sys/class/block/nvme0n1/device/numa_node
/sys/bus/pci/devices/<bdf>/numa_node
```

The operator already has a drive-signing / drive-discovery path
([`operations/sign_drives.go`][sign_drives] + the `DriveInfo`
struct in `internal/pkg/domain/resources.go`). The same Layer 1
metadata bump applies: add `NumaNode *int` to the drive struct,
populate it during signing, carry it through the drive-annotation
pipeline.

[sign_drives]: ../../weka-operator/internal/controllers/operations/sign_drives.go

## What the operator does today

### NIC allocation

[`internal/controllers/wekacontainer/funcs_resources_allocation.go`][funcs_resources_allocation]
`AllocateNICs`:

1. Reads the `weka.io/weka-nics` annotation off the node — a JSON
   array of `domain.NIC` objects.
2. Reads `weka.io/allocations` to see which NICs other containers
   on the node have already claimed.
3. Iterates `allNICs` first-to-last, picks the first
   `NumCores - already_claimed` NICs that aren't in the allocated
   set.
4. Updates the node's `weka.io/allocations` annotation.

Pure first-fit, no preferences. The "one NIC per core" assumption
is hard-coded (`requiredNicsNumber := r.container.Spec.NumCores`).

### NIC metadata

[`internal/pkg/domain/resources.go`][resources]:

```go
type NIC struct {
    MacAddress      string `json:"mac_address,omitempty"`
    PrimaryIP       string `json:"primary_ip,omitempty"`
    SubnetCIDRBlock string `json:"subnet_cidr_block,omitempty"`
}
```

No NUMA field. Nothing identifies which socket a NIC is attached
to.

### Core allocation

The operator doesn't pick physical cores — it just sets `NumCores`
on the WekaContainer and lets kubelet's CPU Manager decide. Which
specific cores the pod gets depends on kubelet's policy at pod
admission time and is invisible to the operator from the API.

### Topology Manager

The operator codebase contains zero references to NUMA, sockets,
or kubelet's Topology Manager. NUMA alignment is unavailable both
in **data** (NIC NUMA unknown) and in **placement** (cores and
NICs not coordinated).

[funcs_resources_allocation]: ../../weka-operator/internal/controllers/wekacontainer/funcs_resources_allocation.go
[resources]: ../../weka-operator/internal/pkg/domain/resources.go

## Code change layers

Four layers, ordered minimal to full. Each builds on the previous.

### Layer 1 — metadata plumbing

Add `NumaNode *int` to `domain.NIC` **and** `domain.DriveInfo`.
Update the HyperPod NIC annotator and the operator's drive-signing
path to populate it from
`/sys/class/net/{iface}/device/numa_node` and
`/sys/class/block/{dev}/device/numa_node` respectively. Operator
ignores the fields initially — just a compatible schema bump on
both annotations.

- **Files**: `internal/pkg/domain/resources.go`,
  `manifests/core/nic-annotator-*.yaml`,
  `lifecycle-scripts/configure-hyperpod-nics.py`,
  `internal/controllers/operations/sign_drives.go` (drive side).
- **LOC**: ~25.
- **Value alone**: zero. Unlocks Layers 2/3/4 for both NICs and
  drives.

### Layer 2 — NUMA-aware first-fit in `AllocateNICs` and drive allocation

Group NICs by `NumaNode`, prefer all-from-one-NUMA when possible,
fall back to mixed only if a single NUMA can't satisfy the
container's NIC count.

Extend the same pattern to drive allocation for drive containers:
prefer drives on a single NUMA, fall back only when the physical
drive layout can't satisfy the container's capacity request from
one socket. Relevant code lives in
`internal/controllers/allocator/` (drive allocation strategies).

- **Files**:
  `internal/controllers/wekacontainer/funcs_resources_allocation.go`,
  `internal/controllers/allocator/*.go`.
- **LOC**: ~80 + tests (split roughly evenly between NIC and
  drive paths).
- **Limitation**: the operator still can't predict which NUMA the
  pod's *cores* will land on. Within-container consistency for
  NICs and drives, but cores may or may not align. Maybe ~30–40%
  of the full win.

### Layer 3 — kubelet Topology Manager contract

Set the WekaContainer pod spec to **Guaranteed QoS** (CPU/memory
requests == limits, integer CPU count) so kubelet's CPU Manager
will pin the pod's cores. Combine with node-level kubelet config:

```text
--cpu-manager-policy=static
--topology-manager-policy=single-numa-node
--topology-manager-scope=pod
```

With those settings, Topology Manager **refuses to admit** any pod
whose CPU + device requests can't all fit on one NUMA node. Any
pod that does start IS NUMA-aligned.

Two ways to close the "operator doesn't know which NUMA" gap:

**3a — post-admission observation.** After the pod is `Running`,
discover which NUMA it landed on by reading
`/sys/fs/cgroup/cpuset.cpus` from inside the container, resolve to
NUMA node, then either annotate the pod (operator reads, allocates
NICs from the matching NUMA) or have WEKA pick NICs itself from a
pool the operator provides.

**3b — partition via multiple WekaContainers per node.** Create
one WekaContainer per NUMA node, with per-container nodeAffinity
matching node-label slots like `weka.io/numa-slot=0`,
`weka.io/numa-slot=1`. k8s doesn't natively partition a node into
labeled sub-slots though, so this requires either extended
resources or a device plugin to advertise per-NUMA capacity.

### Layer 4 — SR-IOV-style device plugin (the idiomatic fix)

Write a device plugin that advertises each WEKA NIC as a k8s
device (`weka.io/nic`, one per interface) **and** each signed WEKA
drive as a k8s device (`weka.io/drive`, one per NVMe). Device
plugins report per-device NUMA topology to kubelet, and Topology
Manager **guarantees** the pod's CPUs + WEKA NICs + WEKA drives
are all NUMA-aligned at admission time. The operator just requests
`N × weka.io/nic` and (for backends) `M × weka.io/drive` in the
pod spec; kubelet does the rest.

This is how SR-IOV networking, NVIDIA GPUs, and EFA devices
already get NUMA-aligned in k8s. It's the "correct" answer but a
medium engineering effort:

- New Go binary (device plugin) running as a DaemonSet on HyperPod
  / backend nodes.
- Coordinates with the NIC-move lifecycle script (for the NIC
  half) and with drive-signing output (for the drive half).
  Replaces the NIC annotator DaemonSet and subsumes drive-pool
  annotations.
- Removes the `weka.io/weka-nics` and drive-annotation pathways;
  replaces with k8s resources.
- Operator's `AllocateNICs` and drive allocator become
  unnecessary — kubelet handles it via Topology Manager.

- **Files**: new `weka-device-plugin/` module, removal/rewrite of
  `internal/controllers/operations/ensure_nics.go`,
  `internal/controllers/operations/sign_drives.go` (drive-pool
  publishing portion), and the HyperPod NIC annotator manifests
  in our repo.
- **LOC**: ~800–1200 + substantial tests.

## Recommendation

**For the operator team**: Layer 1 + Layer 4. Layer 4 hands NUMA
correctness to kubelet (the right owner), and Layer 1 is a cheap
precursor that stays useful regardless.

**For the HyperPod modules short-term**: implement Layer 1 on
our side (lifecycle script + NIC annotator in hyperpod-dedicated;
same plus drive-side capture in hyperpod-axon when that module
ships). Metadata is in place when the operator catches up;
nothing operator-side breaks.

**Avoid Layer 2 alone** — 40 LOC for ~30% of the win, and the
remaining 70% needs kubelet coordination anyway. Half-measure that
risks looking complete.

## Suggested next steps

1. File a feature request with the operator team pointing at
   Layer 4 as the target end state. Call out that the device
   plugin needs to cover both NICs (all deployments) and drives
   (backend / Axon deployments).
2. Stage Layer 1 metadata changes on the HyperPod side
   (lifecycle script + NIC annotator in hyperpod-dedicated) so
   NIC NUMA info is in place when the operator catches up.
   Drive-side Layer 1 will have a natural staging point in
   hyperpod-axon's lifecycle scripts when that module ships;
   until then it's operator-only.
3. Document NUMA as a known limitation on `ml.p5.*` / `ml.p6.*`
   instance types in the client deployment guides, and on any
   dual-socket backend hosts (i3en.metal, i4i.metal,
   i8ge.metal-class) in the Axon guide, until Layer 4 lands.
