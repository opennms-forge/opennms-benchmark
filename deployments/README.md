# Deployment Library

A **deployment** is a "topology under test": which components run, how many nodes
of each, and how they are grouped — expressed as provider-agnostic data. One
deployment can be provisioned onto any Terraform provider and can host many
**experiments** (the workloads run against it).

```
deployments/
  <slug>/
    topology.yml     # the provider-agnostic spec (source of truth)
  bin/
    topology-descriptor.py   # derive the canonical descriptor from a spec
```

## Status (Phase 2)

The specs and tooling here are live. The Terraform **consumption** of a spec —
translating it into a provider's `local.topology` so `make deploy DEPLOYMENT=…
PROVIDER=…` provisions it — lands in Phase 2b, once the Phase 1 `for_each`
refactor (topology-as-data) is merged per provider. Until then, `make
deployments` / `make deployment` list and validate the library, and the
descriptor tool works standalone.

## Spec schema (`topology.yml`)

```yaml
name: mimir-ha                 # must equal the directory slug
description: 3-node HA Mimir stack, multi-Minion, nl6 load
roles:                         # keyed by component role
  elasticsearch:
    count: 3                   # node count (0 or omit = excluded)
    size: large                # t-shirt class (see below)
    subnets: [mgmt, db]        # ordered; first is the mgmt/primary NIC
    groups: [elasticsearch, docker_engine]   # Ansible inventory groups
  minion:
    count: 2
    size: small
    subnets: [mgmt, kafka, sim]
    routes: { sim: net_sim }   # named static route on the given subnet's NIC
    groups: [minion]
  monitoring:
    count: 1
    size: small
    subnets: [mgmt, external]
    public_ip: true            # jump host (external/DHCP NIC + public reachability)
    groups: [mon_servers, docker_engine, grafana]
```

### Roles → component codes

Each role maps to a stable 2–3 char code used in the canonical descriptor:

| role | code | role | code |
|---|---|---|---|
| `core` | `on` | `elasticsearch` | `es` |
| `minion` | `mn` | `mimir` | `mm` |
| `sentinel` | `sn` | `victoriametrics` | `vm` |
| `database` | `pg` | `clickhouse` | `ch` |
| `kafka` | `kf` | `akvorado` | `ak` |
| `rrd` | `rr` | `loadgen` (nl6) | `nl6` |

`monitoring` is always-present infrastructure (Grafana/Prometheus/Jaeger) and is
**excluded** from the descriptor. `loadgen` is the nl6 generator — included by
default; opt out by omitting the role or setting `count: 0`.

### Size classes (provider translates to concrete resources)

| class | vCPU | RAM | notes |
|---|---|---|---|
| `small` | 2 | 4 GiB | db, kafka, minion, netsim, mon |
| `medium` | 2 | 8 GiB | |
| `large` | 4 | 8 GiB | elasticsearch |
| `xlarge` | 4 | 16 GiB | core |

Each provider owns the class → SKU/flavour mapping (Azure `Standard_D*`, Hetzner
`cx*`, or explicit `cores`/`memory` for libvirt/proxmox). Disk sizes come from
the provider's `disk_sizes_gb` keyed by role.

### Subnets

`mgmt` (management + Ansible/SSH), `db`, `kafka`, `sim` (SNMP simulation),
`external` (DHCP bridge for the monitoring jump host). Interface order in
`subnets` fixes NIC order on the VM.

## Identifier scheme

- **slug** — the human handle (kebab-case), equals the directory name; used as
  hostname prefix, Terraform workspace, and Grafana label.
- **canonical descriptor** — machine-derived from the spec, `<count><code>`
  tokens in a fixed order joined by `-` (e.g. `3es-3mm-1pg-3sn-3kf-1on-2mn-nl6`).
  Used as the reproducibility fingerprint on results. Generate with:

  ```bash
  make deployment DEPLOYMENT=mimir-ha        # or:
  python3 deployments/bin/topology-descriptor.py deployments/mimir-ha/topology.yml
  ```

Descriptor component order: `es mm vm ch ak rr pg sn kf on mn nl6`.

## Deployment index

| slug | descriptor | notes |
|---|---|---|
| `baseline` | `1es-1pg-1kf-1on-1mn-nl6` | the current single-node lab (reference) |
| `mimir-ha` (A) | `3es-3mm-1pg-3sn-3kf-1on-2mn-nl6` | full HA Mimir + Sentinel |
| `rrd-minimal` (B) | `1rr-1pg-1kf-1on-1mn` | RRDTool on core, minimal |
| `vm-cluster-es` (C) | `1es-3vm-1pg-1on` | VictoriaMetrics cluster + ES flows |
| `es-nostore` (D) | `1es-1pg-1kf-1on-1mn` | ES flows, no metrics TSDB |
| `vm-cluster-minion` (E) | `3vm-1pg-1kf-1on-1mn` | VictoriaMetrics cluster + minion |
| `vm-single` (F) | `1vm-1pg-1on` | single VictoriaMetrics |
| `mimir-single` (G) | `1mm-1pg-1on` | single Mimir |
| `clickhouse-akvorado` (H) | `1ch-1ak` | standalone flow-engine (no OpenNMS) |
| `es-cluster-min` | `3es` | **component test bed**, not A–H — verifies Elasticsearch cluster formation on a footprint that fits the lab (28 GB) |
| `kafka-cluster-min` | `3kf` | **component test bed**, not A–H — verifies KRaft cluster formation (shared cluster ID, quorum, RF 3) at 28 GB |

**Interpretation notes:** B lists RRDTool without a Core, but RRD is a Core
storage strategy, so `baseline`/B include `core` with the RRD strategy set at the
Ansible layer. Components beyond the current lab (mimir, victoriametrics,
clickhouse, akvorado, sentinel) are valid spec data now; their Ansible roles and
provider translation arrive in Phase 3 (component breadth).
