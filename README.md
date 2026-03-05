# terraform-hcloud-k3s

A minimal, composable Terraform/OpenTofu module for deploying production-ready [k3s](https://k3s.io) clusters on [Hetzner Cloud](https://www.hetzner.com/cloud).

This module provisions **infrastructure only** -- servers, networks, firewalls, load balancers, and a working k3s cluster. It deliberately stops there. CNI, ingress controllers, GitOps tools, and everything else are your responsibility, deployed however you prefer (Helm, ArgoCD, Flux, raw manifests).

## Features

- **HA control plane** -- 1 to N master nodes with embedded etcd
- **Flexible worker pools** -- multiple named pools with independent instance types, locations, and counts
- **Private-by-default workers** -- workers have no public IPs by default (configurable per pool); SSH via master-00 bastion
- **Private masters** -- optional private joining masters (master-00 always public as bastion)
- **NAT gateway** -- private nodes reach the internet via master-00 (automatic iptables MASQUERADE)
- **API load balancer** -- optional LB in front of the K8s API for HA
- **Ingress load balancer** -- optional pre-created LB for Hetzner CCM to adopt
- **Hetzner CCM + CSI** -- Cloud Controller Manager and CSI driver installed automatically
- **Deletion protection** -- opt-in protection on servers and load balancers
- **Embedded registry mirror** -- opt-in [Spegel](https://github.com/spegel-org/spegel) for peer-to-peer image distribution
- **Split firewall** -- base firewall (SSH, API, ICMP) on all nodes; ingress firewall (HTTP, HTTPS, NodePort) on workers only
- **Placement groups** -- spread placement for masters and per-pool for workers
- **Graceful drain** -- masters and workers are drained and removed from the cluster on destroy
- **Secure token handling** -- k3s token uploaded via file provisioner, never exposed in plan output
- **SSH host key verification** -- kubeconfig fetch uses `ssh-keyscan` + `StrictHostKeyChecking=yes`
- **Kubeconfig** -- fetched automatically, stored locally and in state for CI/CD
- **Cloud-init hardening** -- fail2ban, unattended-upgrades, custom DNS
- **BYO CNI** -- flannel enabled by default, disable it to bring your own (Cilium, Calico, etc.)

## Architecture

```
                    +-------------------+
                    |   API Load        |
           kubectl--+   Balancer        +--+
                    |   (optional)      |  |
                    +-------------------+  |
                                           |
              +----------------------------+-----------------------------+
              |         Private Network    |                             |
              |                            |                             |
              |  +----------------+  +-----+---------+  +--------------+ +
              |  |  master-00     |  |  master-01    |  |  master-02   | |
              |  |  (bastion)     |  |  (private*)   |  |  (private*)  | |
              |  |  public IP     |  |               |  |              | |
              |  +----------------+  +---------------+  +--------------+ +
              |                                                          |
              |  +----------------+  +----------------+                  |
              |  |  worker-00     |  |  worker-01     |   ...            |
              |  |  (private*)    |  |  (private*)    |                  |
              |  +----------------+  +----------------+                  |
              |                                                          |
              +----------------------------------------------------------+
                          * masters: when master_public_ip = false
                          * workers: when public_ip = false (per pool, default)
```

See [docs/architecture.md](docs/architecture.md) for detailed provisioning flow, security model, and resource graph.

## Quick Start

### From the Terraform Registry

```hcl
module "k3s" {
  source  = "starsflow/k3s/hcloud"
  version = "~> 1.0"

  hcloud_token = var.hcloud_token
  cluster_name = "my-cluster"

  allowed_ssh_cidrs = ["YOUR_IP/32"]
  allowed_api_cidrs = ["YOUR_IP/32"]

  masters = {
    instance_type  = "cx22"
    instance_count = 3
    location       = "nbg1"
  }

  worker_pools = {
    default = {
      instance_type  = "cx22"
      instance_count = 2
      location       = "nbg1"
    }
  }
}
```

### From GitHub

```hcl
module "k3s" {
  source = "github.com/starsflow/terraform-hcloud-k3s"

  # ... same variables as above
}
```

### Deploy

```bash
export TF_VAR_hcloud_token="your-token"
tofu init
tofu apply
```

After apply, use the generated kubeconfig:

```bash
export KUBECONFIG=$(tofu output -raw kubeconfig_path)
kubectl get nodes
```

## Examples

Ready-to-use examples are available in the [`examples/`](examples/) directory:

| Example | Description |
|---|---|
| [dev-cluster](examples/dev-cluster/) | Single master, single worker, no LB |
| [prod-cluster](examples/prod-cluster/) | 3 HA masters (private), API LB, workers, BYO CNI ready |

### Single master dev cluster

```hcl
module "k3s" {
  source  = "starsflow/k3s/hcloud"
  version = "~> 1.0"

  hcloud_token = var.hcloud_token
  cluster_name = "dev"
  stage        = "dev"

  allowed_ssh_cidrs = ["YOUR_IP/32"]
  allowed_api_cidrs = ["YOUR_IP/32"]

  enable_api_lb = false

  masters = {
    instance_type  = "cx22"
    instance_count = 1
    location       = "nbg1"
  }

  worker_pools = {
    default = {
      instance_type  = "cx22"
      instance_count = 1
      location       = "nbg1"
    }
  }
}
```

### Production HA with private masters

```hcl
module "k3s" {
  source  = "starsflow/k3s/hcloud"
  version = "~> 1.0"

  hcloud_token = var.hcloud_token
  cluster_name = "prod"
  stage        = "prod"

  allowed_ssh_cidrs = ["OFFICE_IP/32"]
  allowed_api_cidrs = ["OFFICE_IP/32", "CI_RUNNER_IP/32"]

  master_public_ip = false
  enable_api_lb    = true
  api_lb_type      = "lb11"
  api_lb_location  = "nbg1"

  enable_delete_protection = true

  masters = {
    instance_type  = "cx32"
    instance_count = 3
    location       = "nbg1"
  }

  worker_pools = {
    general = {
      instance_type  = "cx32"
      instance_count = 3
      location       = "nbg1"
    }
  }

  disable_builtin_cni = true  # BYO CNI (Cilium, Calico, etc.)
}
```

### With Cilium and embedded registry

```hcl
module "k3s" {
  source  = "starsflow/k3s/hcloud"
  version = "~> 1.0"

  hcloud_token = var.hcloud_token
  cluster_name = "platform"

  allowed_ssh_cidrs = ["YOUR_IP/32"]
  allowed_api_cidrs = ["YOUR_IP/32"]

  disable_builtin_cni      = true
  enable_embedded_registry = true

  masters = {
    instance_type  = "cx22"
    instance_count = 3
    location       = "nbg1"
  }

  worker_pools = {
    default = {
      instance_type  = "cx32"
      instance_count = 2
      location       = "nbg1"
    }
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `hcloud_token` | Hetzner Cloud API token | `string` | -- | yes |
| `cluster_name` | Name prefix for all resources | `string` | -- | yes |
| `allowed_ssh_cidrs` | CIDRs allowed to SSH | `list(string)` | -- | yes |
| `allowed_api_cidrs` | CIDRs allowed to reach the K8s API | `list(string)` | -- | yes |
| `stage` | Environment stage label | `string` | `"prod"` | no |
| `k3s_version` | K3s version to install | `string` | `"v1.35.1+k3s1"` | no |
| `ssh_port` | SSH port | `number` | `22` | no |
| `network_cidr` | CIDR for the private network | `string` | `"10.0.0.0/8"` | no |
| `subnet_cidr` | CIDR for the subnet | `string` | `"10.0.1.0/24"` | no |
| `network_zone` | Hetzner network zone | `string` | `"eu-central"` | no |
| `master_init_private_ip` | Static private IP for master-00 | `string` | `null` | no |
| `master_public_ip` | Assign public IPs to joining masters | `bool` | `true` | no |
| `allowed_nodeport_cidrs` | CIDRs allowed to reach NodePort services | `list(string)` | `[]` | no |
| `allowed_icmp_cidrs` | CIDRs allowed to send ICMP | `list(string)` | `[]` | no |
| `enable_api_lb` | Create API load balancer | `bool` | `true` | no |
| `api_lb_type` | API LB type | `string` | `"lb11"` | no |
| `api_lb_location` | API LB location | `string` | `"nbg1"` | no |
| `enable_ingress_lb` | Create ingress load balancer | `bool` | `false` | no |
| `ingress_lb_type` | Ingress LB type | `string` | `"lb11"` | no |
| `ingress_lb_location` | Ingress LB location | `string` | `"nbg1"` | no |
| `masters` | Master node configuration | `object(...)` | 1x cx23, nbg1 | no |
| `worker_pools` | Map of worker pool configs | `map(object(...))` | 1x cx23, nbg1 | no |
| `enable_local_storage` | Enable k3s local-path provisioner | `bool` | `false` | no |
| `disable_builtin_cni` | Disable flannel (BYO CNI) | `bool` | `false` | no |
| `install_ccm` | Install Hetzner CCM | `bool` | `true` | no |
| `install_csi` | Install Hetzner CSI | `bool` | `true` | no |
| `ccm_version` | CCM manifest version | `string` | `"v1.22.0"` | no |
| `csi_version` | CSI manifest version | `string` | `"v2.12.0"` | no |
| `enable_embedded_registry` | Enable Spegel registry mirror | `bool` | `false` | no |
| `enable_delete_protection` | Deletion/rebuild protection | `bool` | `false` | no |
| `kubeconfig_path` | Local path to write kubeconfig | `string` | `"./kubeconfig"` | no |
| `dns_servers` | DNS servers for nodes | `list(string)` | `["1.1.1.1", "8.8.8.8"]` | no |

## Outputs

| Name | Description |
|------|-------------|
| `kubeconfig_path` | Path to the kubeconfig file |
| `kubeconfig_content` | Kubeconfig content (sensitive, for CI/CD) |
| `api_endpoint` | K8s API endpoint URL |
| `master_ips` | Map of master name to IP (public or private) |
| `master_private_ips` | Map of master name to private IP |
| `worker_ips` | Map of worker name to IP (public or private) |
| `worker_private_ips` | Map of worker name to private IP |
| `load_balancer_ip` | API LB IPv4 (empty if disabled) |
| `ingress_lb_ip` | Ingress LB IPv4 (empty if disabled) |
| `ingress_lb_name` | Ingress LB name (empty if disabled) |
| `network_id` | Private network ID |
| `ssh_private_key` | Generated SSH private key (sensitive) |
| `ssh_command` | SSH command to connect to master-00 |

## Documentation

- [Architecture](docs/architecture.md) -- provisioning flow, security model, resource graph
- [Networking](docs/networking.md) -- private network, NAT gateway, firewalls, load balancers
- [Comparison](docs/comparison.md) -- how this module compares to kube-hetzner, hetzner-k3s, and others

## Requirements

| Name | Version |
|------|---------|
| Terraform/OpenTofu | >= 1.5.0 |
| hcloud provider | ~> 1.49 |

## License

[MIT](LICENSE)
