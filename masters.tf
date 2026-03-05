## ──────────────────────────────────────────────
## Cloud-init templates
## ──────────────────────────────────────────────
locals {
  # Master-00 acts as NAT gateway when any workers are private
  cloud_init_master_init = templatefile("${path.module}/templates/cloud-init-base.yaml.tftpl", {
    ssh_port           = var.ssh_port
    dns_servers        = var.dns_servers
    enable_nat_gateway = local.any_worker_private
    subnet_cidr        = var.subnet_cidr
    is_nat_client      = false
    gateway_ip         = local.hetzner_gateway_ip
    subnet_prefix      = local.subnet_prefix
  })

  # Joining masters are NAT clients when they have no public IP
  cloud_init_master_join = templatefile("${path.module}/templates/cloud-init-base.yaml.tftpl", {
    ssh_port           = var.ssh_port
    dns_servers        = var.dns_servers
    enable_nat_gateway = false
    subnet_cidr        = ""
    is_nat_client      = !var.master_public_ip
    gateway_ip         = local.hetzner_gateway_ip
    subnet_prefix      = local.subnet_prefix
  })
}

## ──────────────────────────────────────────────
## Master-00: cluster-init node
## ──────────────────────────────────────────────
resource "hcloud_server" "master_init" {
  name               = "${var.cluster_name}-master-00"
  server_type        = local.master_map[local.master_init_key].instance_type
  image              = local.master_map[local.master_init_key].image
  location           = local.master_map[local.master_init_key].location
  placement_group_id = hcloud_placement_group.masters.id
  ssh_keys           = [hcloud_ssh_key.cluster.id]
  firewall_ids       = [hcloud_firewall.base.id]
  user_data          = local.cloud_init_master_init
  delete_protection  = var.enable_delete_protection
  rebuild_protection = var.enable_delete_protection

  labels = merge(local.common_labels, local.master_map[local.master_init_key].labels, {
    "role" = "master"
  })

  network {
    network_id = hcloud_network.cluster.id
    ip         = var.master_init_private_ip
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  lifecycle {
    precondition {
      condition     = var.master_public_ip || var.enable_api_lb
      error_message = "enable_api_lb must be true when master_public_ip is false (private masters need the API LB)."
    }
  }

  depends_on = [
    hcloud_network_subnet.nodes,
    hcloud_load_balancer_network.ingress,
  ]

  connection {
    type        = "ssh"
    user        = "root"
    private_key = local.ssh_private_key
    host        = self.ipv4_address
    port        = var.ssh_port
    timeout     = "5m"
  }

  provisioner "file" {
    content     = random_password.k3s_token.result
    destination = "/root/.k3s-token"
  }

  provisioner "remote-exec" {
    inline = [templatefile("${path.module}/templates/k3s-server-init.sh.tftpl", {
      k3s_version          = var.k3s_version
      cluster_name         = var.cluster_name
      tls_san              = local.tls_san_lb != "" ? local.tls_san_lb : self.ipv4_address
      private_ip           = self.network.*.ip[0]
      node_name            = self.name
      enable_local_storage    = var.enable_local_storage
      disable_builtin_cni     = var.disable_builtin_cni
      enable_embedded_registry = var.enable_embedded_registry
    })]
  }
}

## ──────────────────────────────────────────────
## Joining masters (master-01, master-02, …)
## ──────────────────────────────────────────────
resource "hcloud_server" "masters" {
  for_each           = local.master_join_map
  name               = "${var.cluster_name}-${each.key}"
  server_type        = each.value.instance_type
  image              = each.value.image
  location           = each.value.location
  placement_group_id = hcloud_placement_group.masters.id
  ssh_keys           = [hcloud_ssh_key.cluster.id]
  firewall_ids       = [hcloud_firewall.base.id]
  user_data          = local.cloud_init_master_join
  delete_protection  = var.enable_delete_protection
  rebuild_protection = var.enable_delete_protection

  labels = merge(local.common_labels, each.value.labels, {
    "role" = "master"
  })

  network {
    network_id = hcloud_network.cluster.id
  }

  public_net {
    ipv4_enabled = var.master_public_ip
    ipv6_enabled = var.master_public_ip
  }

  depends_on = [
    hcloud_network_subnet.nodes,
    hcloud_server.master_init,
  ]

  connection {
    type        = "ssh"
    user        = "root"
    private_key = local.ssh_private_key
    host        = var.master_public_ip ? self.ipv4_address : self.network.*.ip[0]
    port        = var.ssh_port
    timeout     = "5m"

    bastion_host        = var.master_public_ip ? null : hcloud_server.master_init.ipv4_address
    bastion_user        = var.master_public_ip ? null : "root"
    bastion_private_key = var.master_public_ip ? null : local.ssh_private_key
    bastion_port        = var.master_public_ip ? null : var.ssh_port
  }

  provisioner "file" {
    content     = random_password.k3s_token.result
    destination = "/root/.k3s-token"
  }

  provisioner "remote-exec" {
    inline = [templatefile("${path.module}/templates/k3s-server-join.sh.tftpl", {
      k3s_version          = var.k3s_version
      cluster_name         = var.cluster_name
      tls_san              = local.tls_san_lb != "" ? local.tls_san_lb : hcloud_server.master_init.ipv4_address
      server_ip            = hcloud_server.master_init.network.*.ip[0]
      private_ip           = self.network.*.ip[0]
      node_name            = self.name
      enable_local_storage    = var.enable_local_storage
      disable_builtin_cni     = var.disable_builtin_cni
      enable_embedded_registry = var.enable_embedded_registry
    })]
  }
}

## ──────────────────────────────────────────────
## Graceful drain on destroy (joining masters)
## ──────────────────────────────────────────────
resource "null_resource" "master_drain" {
  for_each = local.master_join_map

  triggers = {
    node_name       = "${var.cluster_name}-${each.key}"
    kubeconfig_path = var.kubeconfig_path
    server_id       = hcloud_server.masters[each.key].id
  }

  depends_on = [null_resource.fetch_kubeconfig]

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      if [ -f "${self.triggers.kubeconfig_path}" ]; then
        echo "Draining node ${self.triggers.node_name}..."
        kubectl --kubeconfig="${self.triggers.kubeconfig_path}" \
          drain "${self.triggers.node_name}" \
          --ignore-daemonsets --delete-emptydir-data --force --timeout=120s 2>/dev/null || true
        echo "Removing node ${self.triggers.node_name} from cluster..."
        kubectl --kubeconfig="${self.triggers.kubeconfig_path}" \
          delete node "${self.triggers.node_name}" --timeout=60s 2>/dev/null || true
      fi
    EOT
  }
}
