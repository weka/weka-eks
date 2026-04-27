# HyperPod Instance Type Reference

EC2 specs for HyperPod-supported instance types relevant to WEKA Axon
deployments. Resource planning matters more for axon than for
hyperpod-dedicated because backend processes (drives + compute) and
client processes share the same nodes — drives, NICs, hugepages, and
cores all need to budget against each other.

## Specs

| Instance type | vCPUs | Max network cards | Max ENIs | EFA | Bandwidth |
| --- | --- | --- | --- | --- | --- |
| `ml.p5.4xlarge` | 16 | 1 | 4 | yes | — |
| `ml.p4d.24xlarge` | 96 | 4 | 60 | yes | 4× 100 Gbps |
| `ml.p4de.24xlarge` | 96 | 4 | 60 | yes | 4× 100 Gbps |
| `ml.p5.48xlarge` | 192 | 32 | 64 | yes | 3,200 Gbps |
| `ml.p5e.48xlarge` | 192 | 32 | 64 | yes | 3,200 Gbps (H200) |
| `ml.p5en.48xlarge` | 192 | 32 | 64 | yes | 3,200 Gbps (H200, high mem) |
| `ml.trn1.32xlarge` | 128 | 8 | 50 | yes | 8× 100 Gbps (Trainium) |
| `ml.p6-b200.48xlarge` | 192 | 8 | 50 | yes | 3,200 Gbps (B200 Blackwell) |
| `ml.p6-b300.48xlarge` | 192 | 17 | 50 | yes | 6,400 Gbps (B300 Blackwell) |

`ml.p6e-gb200.36xlarge` (17 cards, 39 EFAs, 50 ENIs, 3,200 Gbps) is
**not** HyperPod-supported.

## EFA / ENA notes

EFA devices come in two forms:

- **Standard EFA** — exposes both an EFA endpoint *and* an ENA-side
  ENI with an IP. WEKA grabs the ENA half and drives it with DPDK.
  Routable like normal TCP/IP traffic.
- **EFA-only** — RDMA only, no IP, not usable by WEKA.

The first EFA on an instance must be standard form (the management
plane needs an IP). Additional cards can be either form. To use a
card for WEKA DPDK, it must be configured as standard EFA so the ENA
half is present.

Underlying hardware has shared bandwidth between ENA and EFA traffic
on the same card. The EFA card's headline number (e.g. 100 Gbps) is
the EFA ceiling; the ENA portion is bounded by a separate per-card
ENA limit that's typically lower. AWS doesn't always publish the
exact ENA per-card cap consistently — confirm via instance docs or
testing if it matters for sizing.

## Sizing for WEKA Axon

The lifecycle script auto-detects what HyperPod actually leaves
DOWN-and-unconfigured in the SageMaker namespace. The maximum
`weka_nic_count` is bounded by:

- The number of ENIs HyperPod pre-provisions (varies by instance
  type — only verified empirically for `ml.p4d.24xlarge` so far,
  which exposes 3 candidates after the primary)
- The instance's max network card count (one EFA-capable ENI per
  card)
- The instance's max ENI count (rarely the binding constraint)

For axon, you typically need NICs for:

- 1 per drive process core (`driveCores`)
- 1 per compute process core (`computeCores`)
- 1 per client process core (`clientCores`)
- 1 reserved for the EKS VPC CNI (pod IPs)
- 1 reserved for the primary management interface

So the working budget is `max_network_cards − 2` after subtracting
management + VPC CNI overhead.

## Verifying a new instance type

Deploy a single instance with `weka_nic_count = 0`, then on the
node:

```bash
sudo ip netns exec sagemaker_agent_namespace ip -br link
```

Count the DOWN `enp*` / `ens*` interfaces — that's the ceiling for
`weka_nic_count` on that type.

## TODO before publishing

The `weka_nic_count` ceilings for non-p4d instance types haven't
been empirically verified — this doc captures the reference data so
we don't lose it, but the actual usable count needs measuring on
each type before we surface it in the README.
