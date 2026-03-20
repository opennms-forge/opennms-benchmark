---
stepsCompleted: [1, 2, 3, 4]
inputDocuments: []
session_topic: 'Migrate azcli/benchmark-lab.sh to Terraform supporting Azure and KVM providers'
session_goals: 'Create a migration plan with decisions around module structure, provider abstraction, and multi-target support'
selected_approach: 'ai-recommended'
techniques_used: ['First Principles Thinking', 'Morphological Analysis', 'Constraint Mapping']
ideas_generated: ['Compute#1 Co-location Constraint', 'Network#1 RFC5737 Address Space', 'Compute#2 Cloud-Init IP Injection', 'Network#2 Management Subnet as Measurement Plane', 'Network#3 /etc/hosts Injection', 'Decision#1 Drop Azure Private DNS Zone']
context_file: ''
session_active: false
workflow_completed: true
---

## Session Overview

**Topic:** Migrate `azcli/benchmark-lab.sh` to Terraform supporting Azure and KVM providers
**Goals:** Create a migration plan with decisions around module structure, provider abstraction, and multi-target support

### Session Setup

_Session initialized 2026-03-19. Existing script provisions 6-VM benchmark lab on Azure with 4 subnets, multi-NIC VMs, NSG, route table, and private DNS. Goal is to support both Azure and KVM (libvirt) as deployment targets._

---

## Technique Execution Results

### Phase 1: First Principles Thinking (complete)

**[Compute #1]: Co-location Constraint**
_Concept:_ VMs must be connected by a network that is benchmark-transparent — latency and bandwidth between VMs should be negligible relative to the workload being measured. On Azure this is expressed as a Proximity Placement Group. On KVM single-host it is implicit. On KVM multi-host it becomes a placement recommendation, not a hard constraint.
_Novelty:_ The Terraform module should document this expectation rather than enforce it universally — some primitives are guarantees, others are recommendations.

**[Network #1]: RFC 5737 Address Space as Lab Invariant**
_Concept:_ `192.0.2.0/24` is fixed across both Azure and KVM deployments. It is RFC 5737 TEST-NET-3 — non-routable by internet standards, unlikely to conflict with production `192.168.x.x` ranges, and load-bearing across Ansible inventory, OpenNMS config, and Prometheus scrape targets.
_Novelty:_ Making this a constant rather than a variable is the right call. Changing it would break the entire application layer config simultaneously.

**[Compute #2]: Cloud-Init as Provider-Agnostic IP Injection Layer**
_Concept:_ Static network configuration is injected per-VM via cloud-init `network-config` v2 templates rendered by Terraform `templatefile()`. The template is shared; only the delivery resource differs between Azure (`custom_data`) and KVM (`libvirt_cloudinit_disk`).
_Novelty:_ IP assignment is a compute-layer concern expressed once in templates, not a network-layer concern duplicated per provider. The libvirt network only needs to provide a bridge.

**[Network #2]: Management Subnet as Measurement Plane**
_Concept:_ `192.0.2.192/26` carries both control-plane traffic (SSH, Ansible) and observability traffic (Prometheus scrapes). The Monitoring VM at `.201` measures all other components through this subnet without touching benchmark-load subnets.
_Novelty:_ Benchmark workload traffic stays on dedicated subnets (db, kafka, sim); measurement traffic stays on mgmt. This topology must be preserved exactly in both providers.

**[Network #3]: /etc/hosts Injection as DNS-Free Hostname Resolution**
_Concept:_ Cloud-init injects a fully-rendered `/etc/hosts` on every VM from a shared Terraform template. All VMs get identical hostname resolution with zero runtime dependencies and no DNS server infrastructure.
_Novelty:_ Eliminates the DNS bootstrapping problem entirely. Since IPs are fixed constants, a dynamic DNS service provides no real benefit over a static hosts file — and adds a failure mode.

**[Decision #1]: Drop Azure Private DNS Zone**
_Rationale:_ Replaced by cloud-init `/etc/hosts` injection. No DNS infrastructure required on either provider.

**[Decision #2]: SNMP Route in Cloud-Init, Not Terraform Network Layer**
_Rationale:_ `10.42.0.0/16 via 192.0.2.134` injected into Minion VM cloud-init `network-config`. Azure route table resource dropped entirely.

**[Network #4]: Monitoring VM as Conditional Jump Host**
_Concept:_ On Azure: static public IP + NSG (SSH from operator CIDR only). On KVM: not needed — VMs directly reachable on local network.
_Novelty:_ Asymmetry made explicit rather than hidden behind abstractions.

**[Constraint #2 refined]: Ubuntu 24.04 LTS Cloud Image**
_Concept:_ Must use `noble-server-cloudimg-amd64.img` from `cloud-images.ubuntu.com` on KVM — not the server ISO. Enforced via `precondition` block. Azure image hardcoded as `Canonical:ubuntu-24_04-lts:server:latest` — not a variable.
_Novelty:_ Hardcoding the correct image per root eliminates silent failure (VM boots but cloud-init never runs).

**[Constraint #1]: 4 libvirt_network Resources Replace 1 Azure VNet**
_Concept:_ libvirt uses isolated bridge networks. One `libvirt_network` per segment: db, kafka, sim, mgmt.

---

### Phase 2: Morphological Analysis (complete)

| Axis | Decision |
|---|---|
| Provider abstraction | Pattern B — separate roots (`terraform/azure/`, `terraform/kvm/`) |
| Module boundaries | Network/compute split per root |
| cloud-init templates | Single parameterized template (`network-config.yaml.tftpl`) |
| Variable structure | Layered tfvars: shared `lab.tfvars` + provider-specific |
| State backend | Local state |

### Phase 3: Constraint Mapping (complete)

**Shared — same concept, same implementation:**

| Concern | Shared mechanism |
|---|---|
| IP assignments | `lab.tfvars` + cloud-init template |
| Hostname resolution | `/etc/hosts` via cloud-init |
| SNMP route | cloud-init Minion network-config |
| Ansible inventory output | `modules/inventory/` |

**Provider-specific — no meaningful abstraction:**

| Concern | Azure | KVM |
|---|---|---|
| Resource grouping | `azurerm_resource_group` | n/a |
| Network primitive | `azurerm_virtual_network` + subnets | `libvirt_network` (4 bridges) |
| Compute | `azurerm_linux_virtual_machine` | `libvirt_domain` |
| Placement | `azurerm_proximity_placement_group` | n/a |
| Ingress | Public IP + NSG | n/a |
| cloud-init delivery | `custom_data` (base64) | `libvirt_cloudinit_disk` |

---

## Idea Organization and Prioritization

### Theme 1: Provider Abstraction Strategy
- Pattern B (separate roots) — no conditionals, clean state separation
- Network/compute split per root — mirrors natural dependency order
- Layered tfvars — shared `lab.tfvars` + `azure.tfvars`/`kvm.tfvars`
- Local state — zero overhead for solo-operated lab

### Theme 2: Network Primitives
- RFC 5737 address space as invariant constant
- 4 libvirt_network bridges vs 1 Azure VNet
- Management subnet as measurement plane
- Conditional jump host (Azure only)

### Theme 3: Cloud-Init as the Shared Abstraction Layer
- Static IP injection via `network-config.yaml.tftpl`
- `/etc/hosts` hostname resolution on all 6 VMs
- SNMP route on Minion only
- Single parameterized template with optional routes list

### Theme 4: Hard Constraints and Guardrails
- Ubuntu 24.04 LTS cloud image enforced via `precondition` block on KVM
- Azure image hardcoded — not a variable
- Network quality guarantee documented, not enforced universally
- Private DNS Zone dropped

### Breakthrough Concepts
- **Cloud-init as the true abstraction boundary** — abstraction lives at the OS config layer, not the provider resource layer
- **Making asymmetry explicit** — `count = 1` on Azure, `count = 0` on KVM

---

## Action Plan

| Step | Action | Output |
|---|---|---|
| 1 | Create directory structure | `terraform/azure/`, `terraform/kvm/`, `terraform/modules/` |
| 2 | Extract IP/hostname constants | `terraform/lab.tfvars` |
| 3 | Build shared cloud-init module | `network-config.yaml.tftpl`, `user-data.yaml.tftpl` |
| 4 | Build Azure network module | VNet, 4 subnets, NICs, public IP, NSG |
| 5 | Build Azure compute module | PPG, 6 VMs with `custom_data` |
| 6 | Build KVM network module | 4 `libvirt_network` bridges |
| 7 | Build KVM compute module | Base volume + `precondition`, 6 `libvirt_domain` |
| 8 | Build inventory module | Ansible inventory from known IPs |
| 9 | Validate Azure root | `terraform init && terraform plan` |
| 10 | Validate KVM root | `terraform init && terraform plan` on KVM host |

**KVM Prerequisites:** Download `noble-server-cloudimg-amd64.img` before `terraform apply`.

---

## Session Summary

**Decisions Made:** 7 | **Primitives Identified:** 8
**Resources eliminated:** Private DNS Zone, route table (replaced by cloud-init)
**Shared code surface:** cloud-init templates, lab.tfvars, inventory module
**Implementation:** PR #1 — https://github.com/indigo423/opennms-benchmark/pull/1
