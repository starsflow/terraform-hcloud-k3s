locals {
  # ── Master map: {"master-00": {index=0, …}, "master-01": {index=1, …}} ──
  master_map = {
    for i in range(var.masters.instance_count) :
    format("master-%02d", i) => {
      index         = i
      instance_type = var.masters.instance_type
      location      = var.masters.location
      image         = var.masters.image
      labels        = var.masters.labels
    }
  }

  # ── Flatten worker pools: {"default-00": {pool, index, …}, "gpu-00": {…}} ──
  worker_map = merge([
    for pool_name, pool in var.worker_pools : {
      for i in range(pool.instance_count) :
      format("%s-%02d", pool_name, i) => {
        pool_name     = pool_name
        index         = i
        instance_type = pool.instance_type
        location      = pool.location
        image         = pool.image
        labels        = merge(pool.labels, { "pool" = pool_name })
        public_ip     = pool.public_ip
      }
    }
  ]...)

  # ── True if any worker pool has private-only nodes ──
  any_worker_private = anytrue([for _, pool in var.worker_pools : !pool.public_ip])

  # ── Hetzner gateway IP (first host in network CIDR) ──
  hetzner_gateway_ip = cidrhost(var.network_cidr, 1)

  # ── Subnet prefix for dynamic interface detection (3 octets for tight match) ──
  subnet_prefix = join(".", slice(split(".", var.subnet_cidr), 0, 3))

  # ── First master is the init node ──
  master_init_key = "master-00"
  master_join_map = {
    for k, v in local.master_map : k => v if k != local.master_init_key
  }

  # ── TLS SAN for k3s certs (must not depend on server resources) ──
  # When LB is disabled, each master provisioner uses self.ipv4_address instead.
  tls_san_lb = var.enable_api_lb ? hcloud_load_balancer.api[0].ipv4 : ""

  # ── SSH private key content (from generated key) ──
  ssh_private_key = tls_private_key.cluster.private_key_openssh

  # ── Common labels ──
  common_labels = {
    "cluster"    = var.cluster_name
    "managed-by" = "terraform"
    "stage"      = var.stage
  }
}
