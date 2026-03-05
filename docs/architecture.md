# Architecture

## Cluster Topology

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

## Node Roles

### master-00 (cluster-init)

The first master is special:

- **Always has a public IP** -- it's the SSH bastion for all private nodes
- Acts as the **NAT gateway** when any workers are private (iptables MASQUERADE)
- Runs the `--cluster-init` flag to bootstrap etcd
- All other nodes join through it

### Joining masters (master-01+)

- Can be **private** when `master_public_ip = false` (requires `enable_api_lb = true`)
- Join the existing cluster via master-00's private IP
- SSH provisioning goes through master-00 as bastion when private
- Are NAT clients when private (route internet traffic through master-00)

### Workers

- **Private by default** (`public_ip = false` per pool)
- Each worker pool gets its own **placement group** (avoids Hetzner's 10-server-per-group limit)
- SSH provisioning goes through master-00 as bastion when private
- Attached to both **base** and **ingress** firewalls (masters only get base)

## Provisioning Flow

1. **Cloud-init** runs first on every node:
   - Installs packages (fail2ban, jq, curl)
   - Configures unattended-upgrades for automatic security patches
   - Sets up custom DNS servers
   - Configures NAT gateway (master-00) or NAT client (private nodes)
   - Adjusts sysctl for Kubernetes

2. **Token upload** via Terraform `file` provisioner:
   - k3s token is written to `/root/.k3s-token` on each node
   - Never passed as a template variable (avoids exposure in plan output)
   - The install script reads and deletes the token file after use

3. **k3s installation** via `remote-exec`:
   - master-00: `--cluster-init` with embedded etcd
   - master-01+: `--server` pointing to master-00's private IP
   - workers: `--server` pointing to master-00's private IP

4. **Kubeconfig fetch**:
   - SSH host key collected via `ssh-keyscan`
   - Kubeconfig downloaded via `scp` with `StrictHostKeyChecking=yes`
   - API endpoint rewritten from `127.0.0.1` to LB IP or master-00 public IP
   - Content stored in Terraform state for CI/CD retrieval

5. **Kubernetes resources** applied via `kubectl`:
   - Hetzner Cloud secret (token + network name)
   - Cloud Controller Manager (CCM)
   - CSI driver

## Destroy Behavior

On `terraform destroy`, both workers and joining masters are:

1. **Drained** (`kubectl drain --ignore-daemonsets --delete-emptydir-data --force`)
2. **Removed** from the cluster (`kubectl delete node`)
3. **Destroyed** (Hetzner server deletion)

This ensures workloads are rescheduled before nodes disappear.

## Security Model

- **SSH keys** are generated per cluster (ED25519), stored in Terraform state and written to `/tmp/`
- **k3s token** is a 48-character random password, never appears in plan output
- **Hetzner Cloud token** is written to a temp YAML file and applied via `kubectl apply -f`, never embedded in shell command strings
- **Firewalls** require explicit CIDRs -- no default `0.0.0.0/0` for SSH or API
- **Input validation** on `kubeconfig_path`, `ccm_version`, `csi_version` prevents shell injection
- **Unattended-upgrades** keeps nodes patched automatically (reboot disabled)

## Resource Graph

```
tls_private_key.cluster
  -> hcloud_ssh_key.cluster
  -> local_sensitive_file.ssh_private_key

random_password.k3s_token

hcloud_network.cluster
  -> hcloud_network_subnet.nodes
  -> hcloud_network_route.nat_gateway (conditional)

hcloud_placement_group.masters
hcloud_placement_group.workers[*]

hcloud_firewall.base
hcloud_firewall.ingress

hcloud_load_balancer.api (conditional)
  -> hcloud_load_balancer_network.api
  -> hcloud_load_balancer_service.api
  -> hcloud_load_balancer_target.master_init
  -> hcloud_load_balancer_target.master_join[*]

hcloud_load_balancer.ingress (conditional)
  -> hcloud_load_balancer_network.ingress

hcloud_server.master_init
  -> hcloud_server.masters[*] (joining masters)
  -> hcloud_server.workers[*]
  -> null_resource.fetch_kubeconfig
     -> data.external.kubeconfig_content
     -> null_resource.hcloud_secret
        -> null_resource.ccm
        -> null_resource.csi
     -> null_resource.master_drain[*]
     -> null_resource.worker_drain[*]
```
