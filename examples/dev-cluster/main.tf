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
  cluster_name = var.cluster_name
  stage        = "dev"

  allowed_ssh_cidrs = var.allowed_ssh_cidrs
  allowed_api_cidrs = var.allowed_api_cidrs

  masters      = var.masters
  worker_pools = var.worker_pools

  enable_api_lb    = var.enable_api_lb
  master_public_ip = var.master_public_ip
  api_lb_type      = var.api_lb_type
  api_lb_location  = var.api_lb_location

  disable_builtin_cni      = var.disable_builtin_cni
  enable_embedded_registry = var.enable_embedded_registry
  enable_ingress_lb        = var.enable_ingress_lb
}
