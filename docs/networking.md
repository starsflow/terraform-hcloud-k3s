# Networking

## Private Network

All nodes are connected via a Hetzner private network:

- **Network CIDR**: `network_cidr` (default `10.0.0.0/8`)
- **Subnet CIDR**: `subnet_cidr` (default `10.0.1.0/24`) -- nodes live here
- **Network zone**: `network_zone` (default `eu-central`)
- **Gateway IP**: always the first host in `network_cidr`, computed via `cidrhost(var.network_cidr, 1)` (default `10.0.0.1`)

## NAT Gateway

Private nodes (no public IP) need internet access for package updates, container image pulls, etc. The module configures master-00 as a NAT gateway:

### How it works

1. A **Hetzner network route** (`0.0.0.0/0 -> master-00 private IP`) is created when `any_worker_private = true`
2. master-00's **cloud-init** configures:
   - IP forwarding (`net.ipv4.ip_forward = 1`)
   - iptables MASQUERADE rule on the public interface
3. Private nodes (NAT clients) get:
   - A default route pointing to master-00's private IP
   - A **networkd-dispatcher** script that re-applies the default route after DHCP renewals

### Interface detection

Network interface names are **not stable** across Hetzner instance types (not always `enp7s0` or `eth0`). The module detects interfaces dynamically:

- **Private interface**: matched by finding the interface whose IP starts with the subnet prefix (first 3 octets of `subnet_cidr`)
- **Public interface** (for NAT masquerade): detected via `ip -o route get 1.1.1.1`

### When NAT is created

| Scenario | NAT gateway | NAT route |
|---|---|---|
| All workers have `public_ip = true` | Not configured | Not created |
| Any worker has `public_ip = false` (default) | master-00 configured | Route created |
| Private joining masters (`master_public_ip = false`) | Already configured (if any worker private) | Already created |

## Firewalls

The module creates two firewalls:

### Base firewall (all nodes)

| Rule | Protocol | Port | Source |
|---|---|---|---|
| SSH | TCP | `ssh_port` (default 22) | `allowed_ssh_cidrs` |
| K8s API | TCP | 6443 | `allowed_api_cidrs` |
| ICMP | ICMP | -- | `allowed_icmp_cidrs` (opt-in, only created if non-empty) |

### Ingress firewall (workers only)

| Rule | Protocol | Port | Source |
|---|---|---|---|
| HTTP | TCP | 80 | `0.0.0.0/0`, `::/0` |
| HTTPS | TCP | 443 | `0.0.0.0/0`, `::/0` |
| NodePort | TCP | 30000-32767 | `allowed_nodeport_cidrs` (opt-in, only created if non-empty) |

Masters do **not** get the ingress firewall -- they don't serve HTTP/HTTPS traffic.

## Load Balancers

### API Load Balancer

When `enable_api_lb = true`:

- Creates a TCP load balancer on port 6443
- All masters (init + joining) are targets via private IPs
- Health checks on TCP 6443 (interval 10s, timeout 5s, 3 retries)
- **Required** when `master_public_ip = false` (enforced by precondition)
- The kubeconfig API endpoint is rewritten to the LB IP

### Ingress Load Balancer

When `enable_ingress_lb = true`:

- Creates a load balancer attached to the private network
- **No services or targets are configured** -- this is intentional
- Hetzner CCM adopts the LB and manages its configuration
- Your ingress controller (Nginx, Traefik, etc.) creates a `LoadBalancer` Service that CCM maps to this pre-created LB

## DNS

Custom DNS servers can be configured via `dns_servers` (default `["1.1.1.1", "8.8.8.8"]`). These are written to `/etc/systemd/resolved.conf.d/` during cloud-init.

## Connectivity Matrix

| From | To | Path |
|---|---|---|
| You -> master-00 | SSH, kubectl | Direct (public IP) |
| You -> private master | SSH | Via master-00 bastion |
| You -> private worker | SSH | Via master-00 bastion |
| You -> K8s API (with LB) | kubectl | Via API load balancer |
| Private node -> internet | apt, images | NAT via master-00 |
| Node -> node | k3s traffic | Private network (10.0.1.0/24) |
