## ──────────────────────────────────────────────
## Worker nodes
## ──────────────────────────────────────────────
resource "hcloud_server" "workers" {
  for_each           = local.worker_map
  name               = "${var.cluster_name}-worker-${each.key}"
  server_type        = each.value.instance_type
  image              = each.value.image
  location           = each.value.location
  placement_group_id = hcloud_placement_group.workers[each.value.pool_name].id
  ssh_keys           = [hcloud_ssh_key.cluster.id]
  firewall_ids       = [hcloud_firewall.base.id, hcloud_firewall.ingress.id]
  user_data = templatefile("${path.module}/templates/cloud-init-base.yaml.tftpl", {
    ssh_port           = var.ssh_port
    dns_servers        = var.dns_servers
    enable_nat_gateway = false
    subnet_cidr        = ""
    is_nat_client      = !each.value.public_ip
    gateway_ip         = local.hetzner_gateway_ip
    subnet_prefix      = local.subnet_prefix
  })
  delete_protection  = var.enable_delete_protection
  rebuild_protection = var.enable_delete_protection

  labels = merge(local.common_labels, each.value.labels, {
    "role" = "worker"
  })

  network {
    network_id = hcloud_network.cluster.id
  }

  public_net {
    ipv4_enabled = each.value.public_ip
    ipv6_enabled = each.value.public_ip
  }

  depends_on = [
    hcloud_network_subnet.nodes,
    hcloud_server.master_init,
    hcloud_network_route.nat_gateway,
  ]

  connection {
    type        = "ssh"
    user        = "root"
    private_key = local.ssh_private_key
    host        = each.value.public_ip ? self.ipv4_address : self.network[*].ip[0]
    port        = var.ssh_port
    timeout     = "5m"

    bastion_host        = each.value.public_ip ? null : hcloud_server.master_init.ipv4_address
    bastion_user        = each.value.public_ip ? null : "root"
    bastion_private_key = each.value.public_ip ? null : local.ssh_private_key
    bastion_port        = each.value.public_ip ? null : var.ssh_port
  }

  provisioner "file" {
    content     = random_password.k3s_token.result
    destination = "/root/.k3s-token"
  }

  provisioner "remote-exec" {
    inline = [templatefile("${path.module}/templates/k3s-agent.sh.tftpl", {
      k3s_version   = var.k3s_version
      server_ip     = hcloud_server.master_init.network[*].ip[0]
      node_name     = self.name
      private_ip    = self.network[*].ip[0]
      is_nat_client = !each.value.public_ip
      gateway_ip    = local.hetzner_gateway_ip
      subnet_prefix = local.subnet_prefix
    })]
  }
}

## ──────────────────────────────────────────────
## Graceful drain on destroy
## ──────────────────────────────────────────────
resource "null_resource" "worker_drain" {
  for_each = local.worker_map

  triggers = {
    node_name       = "${var.cluster_name}-worker-${each.key}"
    kubeconfig_path = var.kubeconfig_path
    server_id       = hcloud_server.workers[each.key].id
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
