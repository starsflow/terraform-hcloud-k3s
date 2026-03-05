## ──────────────────────────────────────────────
## SSH Key (generated, stored in state)
## ──────────────────────────────────────────────
resource "tls_private_key" "cluster" {
  algorithm = "ED25519"
}

resource "hcloud_ssh_key" "cluster" {
  name       = "${var.cluster_name}-key"
  public_key = tls_private_key.cluster.public_key_openssh
  labels     = local.common_labels
}

resource "local_sensitive_file" "ssh_private_key" {
  content         = tls_private_key.cluster.private_key_openssh
  filename        = "/tmp/.ssh-key-${var.cluster_name}"
  file_permission = "0600"
}

## ──────────────────────────────────────────────
## K3s Token (pre-generated, shared by all nodes)
## ──────────────────────────────────────────────
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

## ──────────────────────────────────────────────
## Placement Groups
## ──────────────────────────────────────────────
resource "hcloud_placement_group" "masters" {
  name   = "${var.cluster_name}-masters"
  type   = "spread"
  labels = local.common_labels
}

resource "hcloud_placement_group" "workers" {
  for_each = var.worker_pools
  name     = "${var.cluster_name}-workers-${each.key}"
  type     = "spread"
  labels   = merge(local.common_labels, { "pool" = each.key })
}
