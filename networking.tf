## ──────────────────────────────────────────────
## Private Network
## ──────────────────────────────────────────────
resource "hcloud_network" "cluster" {
  name     = "${var.cluster_name}-net"
  ip_range = var.network_cidr
  labels   = local.common_labels
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_cidr
}

## ──────────────────────────────────────────────
## NAT Gateway route (private workers → master → internet)
## ──────────────────────────────────────────────
resource "hcloud_network_route" "nat_gateway" {
  count       = local.any_worker_private ? 1 : 0
  network_id  = hcloud_network.cluster.id
  destination = "0.0.0.0/0"
  gateway     = one(hcloud_server.master_init.network).ip

  depends_on = [hcloud_network_subnet.nodes]
}

## ──────────────────────────────────────────────
## Firewall
## ──────────────────────────────────────────────
## Base firewall (all nodes): SSH, K8s API, ICMP
resource "hcloud_firewall" "base" {
  name   = "${var.cluster_name}-fw-base"
  labels = local.common_labels

  # SSH
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = tostring(var.ssh_port)
    source_ips = var.allowed_ssh_cidrs
  }

  # K8s API
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = var.allowed_api_cidrs
  }

  # ICMP (opt-in)
  dynamic "rule" {
    for_each = length(var.allowed_icmp_cidrs) > 0 ? [1] : []
    content {
      direction  = "in"
      protocol   = "icmp"
      source_ips = var.allowed_icmp_cidrs
    }
  }
}

moved {
  from = hcloud_firewall.cluster
  to   = hcloud_firewall.base
}

## Ingress firewall (workers only): HTTP, HTTPS, NodePort
resource "hcloud_firewall" "ingress" {
  name   = "${var.cluster_name}-fw-ingress"
  labels = local.common_labels

  # HTTP
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # HTTPS
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # NodePort range (opt-in)
  dynamic "rule" {
    for_each = length(var.allowed_nodeport_cidrs) > 0 ? [1] : []
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "30000-32767"
      source_ips = var.allowed_nodeport_cidrs
    }
  }
}

## ──────────────────────────────────────────────
## Load Balancer (optional, for HA API)
## ──────────────────────────────────────────────
resource "hcloud_load_balancer" "api" {
  count              = var.enable_api_lb ? 1 : 0
  name               = "${var.cluster_name}-api-lb"
  load_balancer_type = var.api_lb_type
  location           = var.api_lb_location
  labels             = local.common_labels
  delete_protection  = var.enable_delete_protection
}

resource "hcloud_load_balancer_network" "api" {
  count            = var.enable_api_lb ? 1 : 0
  load_balancer_id = hcloud_load_balancer.api[0].id
  network_id       = hcloud_network.cluster.id

  depends_on = [hcloud_network_subnet.nodes]
}

resource "hcloud_load_balancer_service" "api" {
  count            = var.enable_api_lb ? 1 : 0
  load_balancer_id = hcloud_load_balancer.api[0].id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer_target" "master_init" {
  count            = var.enable_api_lb ? 1 : 0
  load_balancer_id = hcloud_load_balancer.api[0].id
  type             = "server"
  server_id        = hcloud_server.master_init.id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.api]
}

resource "hcloud_load_balancer_target" "master_join" {
  for_each         = var.enable_api_lb ? local.master_join_map : {}
  load_balancer_id = hcloud_load_balancer.api[0].id
  type             = "server"
  server_id        = hcloud_server.masters[each.key].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.api]
}

## ──────────────────────────────────────────────
## Ingress Load Balancer (optional, managed by CCM)
## ──────────────────────────────────────────────
resource "hcloud_load_balancer" "ingress" {
  count              = var.enable_ingress_lb ? 1 : 0
  name               = "${var.cluster_name}-ingress-lb"
  load_balancer_type = var.ingress_lb_type
  location           = var.ingress_lb_location
  labels             = local.common_labels
  delete_protection  = var.enable_delete_protection
}

resource "hcloud_load_balancer_network" "ingress" {
  count            = var.enable_ingress_lb ? 1 : 0
  load_balancer_id = hcloud_load_balancer.ingress[0].id
  network_id       = hcloud_network.cluster.id

  depends_on = [hcloud_network_subnet.nodes]
}
