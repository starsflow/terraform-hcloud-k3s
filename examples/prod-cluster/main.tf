terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }

  # Configure your backend here, e.g.:
  # backend "http" {}
}

provider "hcloud" {
  token = var.hcloud_token
}

module "k3s" {
  # For local development/testing, use relative path:
  source = "../.."
  # For published module, use:
  # source = "github.com/starsflow/terraform-hcloud-k3s"

  hcloud_token = var.hcloud_token
  cluster_name = "prod"
  stage        = "prod"

  allowed_ssh_cidrs = var.allowed_ssh_cidrs
  allowed_api_cidrs = var.allowed_api_cidrs

  # Private joining masters — API LB required
  master_public_ip = false

  # HA API load balancer
  enable_api_lb   = true
  api_lb_type     = "lb11"
  api_lb_location = "nbg1"

  # Protect against accidental deletion (set true for real prod)
  enable_delete_protection = false

  masters = {
    instance_type  = "cx23"   # cx32 for real prod
    instance_count = 3
    location       = "nbg1"
  }

  worker_pools = {
    general = {
      instance_type  = "cx23"  # cx32 for real prod
      instance_count = 1       # 3 for real prod
      location       = "nbg1"
      # public_ip = false  # default — private workers, NAT via master-00
    }
  }

  # BYO CNI — set true when installing Cilium/Calico manually
  disable_builtin_cni = false
}
