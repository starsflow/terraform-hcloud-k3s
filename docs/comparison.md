# Comparison with Other k3s Hetzner Projects

There are several projects for running k3s on Hetzner Cloud. They differ in scope, philosophy, and complexity. This document compares the four main options so you can pick the right one for your use case.

## At a Glance

| | **starsflow/k3s** | **kube-hetzner** | **hetzner-k3s** | **identiops/k3s** |
|---|---|---|---|---|
| **Type** | Terraform module | Terraform module | CLI tool | Terraform module |
| **GitHub** | [starsflow/terraform-hcloud-k3s](https://github.com/starsflow/terraform-hcloud-k3s) | [kube-hetzner/terraform-hcloud-kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner) | [vitobotta/hetzner-k3s](https://github.com/vitobotta/hetzner-k3s) | [identiops/terraform-hcloud-k3s](https://github.com/identiops/terraform-hcloud-k3s) |
| **Stars** | New | ~3,700 | ~3,300 | ~148 |
| **Philosophy** | Infrastructure only | All-in-one platform | CLI-driven simplicity | Security-first, gateway node |
| **Language** | HCL (Terraform) | HCL (Terraform) | Crystal | HCL (Terraform) |
| **Configuration** | Terraform variables | Terraform variables | YAML file | Terraform variables |
| **OS** | Ubuntu 24.04 | openSUSE MicroOS | Ubuntu (default) | Ubuntu 24.04 |
| **Variables** | ~35 | ~190 | YAML config | ~50 |
| **Packer required** | No | Yes | No | No |
| **OpenTofu compatible** | Yes | Yes | N/A | Yes |

---

## Feature Comparison

### Networking

| Feature | **starsflow/k3s** | **kube-hetzner** | **hetzner-k3s** | **identiops/k3s** |
|---|---|---|---|---|
| Private workers | Yes (default) | Yes | Yes (private network) | Yes (default) |
| Private masters | Yes (opt-in) | Yes | Yes (private network) | Yes (all nodes private) |
| NAT gateway | master-00 (auto) | Dedicated NAT router | Not documented | Gateway node |
| API load balancer | Yes (opt-in) | Yes | Via CCM | No (gateway proxy) |
| Ingress load balancer | Yes (pre-created for CCM) | Yes (auto-configured) | Via CCM | No |
| Firewall | Yes (explicit CIDRs, split base+ingress) | Yes (SSH/API source restrictions) | Yes (Hetzner firewall integration) | Yes (internal + fail2ban) |
| WireGuard encryption | No | Yes (opt-in) | No | No |
| IPv6 / dual-stack | IPv6 on public nodes | Full dual-stack | Not documented | No |
| Custom network CIDR | Yes | Yes (per nodepool) | Not documented | Yes |

### Compute

| Feature | **starsflow/k3s** | **kube-hetzner** | **hetzner-k3s** | **identiops/k3s** |
|---|---|---|---|---|
| HA control plane | Yes (embedded etcd) | Yes (embedded etcd) | Yes | Yes (embedded etcd) |
| Worker pools | Yes (named, independent) | Yes (nodepools) | Yes (node pools) | Yes (node pools) |
| Placement groups | Yes (per pool) | Yes | Not documented | Yes |
| Multi-arch (ARM) | No | Yes (CAX instances) | Yes (CAX instances) | No |
| Multi-region | No | Yes (super-HA) | Yes | Yes |
| Delete protection | Yes (opt-in) | Yes (granular: FIP, LB, volume) | Not documented | Yes (default) |
| Graceful drain on destroy | Yes (automatic) | Yes (manual documented) | Not documented | Yes (manual documented) |

### Kubernetes Components

| Feature | **starsflow/k3s** | **kube-hetzner** | **hetzner-k3s** | **identiops/k3s** |
|---|---|---|---|---|
| CNI | Flannel (default) or BYO | Flannel, Calico, or Cilium | Flannel or Cilium | Cilium (default) |
| BYO CNI | Yes (`disable_builtin_cni`) | No (must pick from built-in) | No (must pick from built-in) | No |
| Ingress controller | None (BYO) | Traefik, Nginx, or HAProxy | Traefik (optional) | None (BYO) |
| Hetzner CCM | Yes (auto-installed) | Yes | Yes | Yes |
| Hetzner CSI | Yes (auto-installed) | Yes | Yes | Yes |
| Longhorn storage | No | Yes (opt-in) | No | No |
| Local-path provisioner | Yes (opt-in) | No | Not documented | No |
| Embedded registry (Spegel) | Yes (opt-in) | No | No | Yes |

### Operations

| Feature | **starsflow/k3s** | **kube-hetzner** | **hetzner-k3s** | **identiops/k3s** |
|---|---|---|---|---|
| Auto OS upgrades | No (BYO) | Yes (MicroOS transactional + kured) | Not documented | Yes (kured) |
| Auto k3s upgrades | No (BYO) | Yes (SUC) | Yes (SUC) | Yes (SUC) |
| etcd S3 backups | No | Yes | No | Yes |
| Cluster autoscaler | No (BYO) | Yes (built-in) | Yes (built-in) | Planned |
| cert-manager | No (BYO) | Yes (via Kustomization) | No | No |
| Metrics server | No (BYO) | Not documented | Not documented | Yes |
| Cluster creation speed | ~5-10 min | ~10-15 min (includes Packer) | ~2-3 min (3 nodes) | ~5-10 min |

### Security

| Feature | **starsflow/k3s** | **kube-hetzner** | **hetzner-k3s** | **identiops/k3s** |
|---|---|---|---|---|
| Token handling | File provisioner (never in plan) | Not documented | Stays local | Not documented |
| SSH key management | Generated per cluster (ED25519) | Configurable | Configurable | Configurable |
| SSH host key verification | Yes (ssh-keyscan + StrictHostKeyChecking) | Not documented | Not documented | Not documented |
| fail2ban | Yes (cloud-init) | Yes (MicroOS) | Not documented | Yes |
| Unattended security patches | Yes (cloud-init) | Yes (MicroOS transactional) | Not documented | Yes (kured) |
| SELinux | No | Yes (MicroOS) | No | No |
| Input validation (injection prevention) | Yes (regex on paths/versions) | Not documented | Not documented | Not documented |
| OIDC authentication | No | No | No | Planned |

---

## Project Deep Dives

### starsflow/k3s (this module)

**Approach**: Infrastructure only. Provisions servers, networks, firewalls, load balancers, and a working k3s cluster with CCM/CSI. Everything else (CNI, ingress, GitOps, monitoring) is deployed separately.

**Architecture**: master-00 is always public (bastion + NAT gateway). Joining masters can be private with an API load balancer. Workers are private by default, reaching the internet via NAT through master-00. Two firewalls: base (SSH, API, ICMP) on all nodes, ingress (HTTP, HTTPS, NodePort) on workers only.

**Strengths**:
- Simplest variable surface (~35 variables)
- Clean separation: infrastructure lifecycle is decoupled from platform lifecycle
- No Packer, no MicroOS snapshots, no external dependencies beyond Terraform
- Composable with Terragrunt, Atmos, or any Terraform orchestrator
- Secure defaults: explicit CIDRs required, token never in plan output, SSH host key verification
- Automated test suite (Terratest) covering HA, scaling, drain, NAT, BYO CNI

**Limitations**:
- No auto-upgrades (OS or k3s) -- you manage this yourself
- No ARM/CAX support
- No WireGuard overlay encryption
- No etcd backups -- bring your own backup strategy
- No cluster autoscaler -- scale by changing `instance_count`

**Best for**: Teams that already have platform tooling (Helm, ArgoCD, Flux) and want a clean infrastructure layer they fully control. If you use Terraform to manage infrastructure and something else to manage Kubernetes workloads, this is for you.

---

### kube-hetzner

**Approach**: All-in-one platform. A single `tofu apply` gives you a fully configured Kubernetes cluster with CNI, ingress, autoscaling, auto-upgrades, and more.

**Architecture**: Uses openSUSE MicroOS (immutable OS) which requires building a Packer snapshot before first use. Supports a dedicated NAT router for fully private clusters. Nodepools with custom CIDR blocks per pool. Optional WireGuard encryption for pod traffic.

**Strengths**:
- Most feature-complete: CNI choice, ingress controller, autoscaler, cert-manager, Longhorn, auto-upgrades all built in
- MicroOS provides immutable infrastructure with BTRFS snapshot rollback
- SELinux hardened out of the box
- ARM/CAX support for cost optimization
- Multi-region (super-HA) deployment
- Large community (~3,700 stars)
- Dual-stack IPv4/IPv6
- etcd S3 backup and restore built in
- Granular delete protection (floating IPs, LBs, volumes)

**Limitations**:
- ~190 variables -- significant learning curve
- Requires Packer to build MicroOS snapshots before first apply
- Everything in one Terraform state: upgrading ingress means re-running Terraform
- MicroOS is unfamiliar to most teams (not Ubuntu/Debian)
- Swapping CNI or ingress requires modifying the module configuration

**Best for**: Teams that want a fully managed platform from a single tool and don't plan to layer their own platform tooling on top. Good if you want batteries-included and are OK with the complexity.

---

### hetzner-k3s (CLI)

**Approach**: Single binary CLI tool. No Terraform, Packer, or Ansible required. Configure a YAML file, run `hetzner-k3s create`, get a cluster.

**Architecture**: Communicates directly with the Hetzner API. Provisions nodes, installs k3s, configures networking over Hetzner's private network by default. Uses Hetzner CCM for load balancers. Supports multi-region deployments across Hetzner locations.

**Strengths**:
- Fastest cluster creation (~2-3 min for 3 nodes, ~11 min for 500 nodes)
- Simplest setup: one binary, one YAML file
- No external dependencies (no Terraform, Packer, Ansible)
- Private networking by default (Hetzner private network)
- Hetzner firewall integration
- Built-in cluster autoscaler
- ARM/CAX support
- Multi-region deployments
- Built-in k3s auto-upgrades via SUC
- Credentials stay local (token never uploaded anywhere)

**Limitations**:
- Not composable with other IaC (not Terraform, can't mix with other modules)
- No placement groups documented
- No delete protection documented
- No etcd backups documented
- State is not in Terraform -- no plan/apply workflow, no drift detection

**Best for**: Developers who want a cluster fast and don't use Terraform. Great for personal projects, experiments, and situations where speed matters more than IaC composability.

---

### identiops/k3s

**Approach**: Security-first Terraform module. All cluster nodes are private by design. A dedicated **gateway node** handles all external access -- no cluster node has a public IP.

**Architecture**: Gateway node is the single point of entry (SSH, kubectl port-forwarding). Control plane and workers sit behind the gateway with no public interfaces. Internal firewalls on all nodes. Cilium is the only CNI (no choice, but Cilium is excellent). Includes kured for OS reboots, SUC for k3s upgrades, and etcd S3 backups.

**Strengths**:
- Strongest security defaults: no public IPs on any cluster node, delete protection on by default
- Gateway node architecture -- clean separation of access plane and data plane
- etcd S3 backups built in
- Auto-upgrades for both OS (kured) and k3s (SUC)
- Embedded registry (Spegel) for fast image distribution
- Convenience scripts (ssh-node, scp-node, ls-nodes, setkubeconfig)
- Ansible inventory auto-generation
- Monthly cost estimates in documentation
- K3s hardening guide applied (kernel parameters, audit logging)

**Limitations**:
- Cilium-focused -- no documented BYO CNI or Flannel option
- No API load balancer -- kubectl access is via port-forwarding through the gateway
- No ARM/CAX support
- No cluster autoscaler (planned)
- ~50 variables -- moderate complexity
- Gateway node is a single point of failure for access (not for cluster operation)
- Smaller community (~148 stars)

**Best for**: Security-conscious teams that want zero public exposure on cluster nodes and are comfortable with Cilium. Good if you want strong defaults without configuring every security knob yourself.

---

## Decision Matrix

| If you need... | Use |
|---|---|
| Clean infrastructure layer, manage platform yourself | **starsflow/k3s** |
| Composability with Terragrunt/Atmos/other Terraform | **starsflow/k3s** |
| Fewest variables, simplest config | **starsflow/k3s** (~35 vars) |
| Everything built-in from one `tofu apply` | **kube-hetzner** |
| Auto-upgrades, autoscaling, ingress out of the box | **kube-hetzner** |
| Immutable OS with snapshot rollback | **kube-hetzner** (MicroOS) |
| Fastest cluster creation, no Terraform | **hetzner-k3s** (CLI) |
| ARM/CAX cost optimization | **kube-hetzner** or **hetzner-k3s** |
| Zero public IPs on cluster nodes | **identiops/k3s** (gateway) |
| etcd S3 backups built in | **kube-hetzner** or **identiops/k3s** |
| BYO CNI (Cilium, Calico, anything) | **starsflow/k3s** |
| WireGuard pod traffic encryption | **kube-hetzner** |

## Why This Module Exists

This module draws a clear boundary: **infrastructure stops at k3s**.

Other modules bundle CNI selection, ingress controllers, storage backends, autoscalers, and upgrade controllers into the same Terraform state. That coupling means:

- Upgrading your ingress controller requires `tofu apply` on infrastructure
- Swapping CNIs means modifying the cluster module and re-running Terraform
- A bad Helm release can block infrastructure changes
- Your Terraform plan touches 200+ resources even when you only changed a node count

By keeping the module thin, each concern has its own lifecycle:

- Your CNI upgrades independently of your node count
- Your GitOps tool deploys without touching Terraform
- Your ingress controller is a Helm chart, not a Terraform variable
- Infrastructure changes are fast and predictable
