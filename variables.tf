## ──────────────────────────────────────────────
## Auth
## ──────────────────────────────────────────────
variable "hcloud_token" {
  description = "Hetzner Cloud API token (use TF_VAR_hcloud_token)"
  type        = string
  sensitive   = true
}

## ──────────────────────────────────────────────
## Cluster identity
## ──────────────────────────────────────────────
variable "cluster_name" {
  description = "Name prefix for all resources"
  type        = string
}

variable "stage" {
  description = "Environment stage (prod, dev, staging)"
  type        = string
  default     = "prod"
}

## ──────────────────────────────────────────────
## K3s
## ──────────────────────────────────────────────
variable "k3s_version" {
  description = "K3s version to install"
  type        = string
  default     = "v1.35.1+k3s1"
}

## ──────────────────────────────────────────────
## SSH
## ──────────────────────────────────────────────
variable "ssh_port" {
  description = "SSH port"
  type        = number
  default     = 22
}

## ──────────────────────────────────────────────
## Networking
## ──────────────────────────────────────────────
variable "network_cidr" {
  description = "CIDR for the private network"
  type        = string
  default     = "10.0.0.0/8"
}

variable "subnet_cidr" {
  description = "CIDR for the subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "network_zone" {
  description = "Hetzner network zone"
  type        = string
  default     = "eu-central"
}

variable "master_init_private_ip" {
  description = "Static private IP for the cluster-init master (null = auto-assign)"
  type        = string
  default     = null
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH (no default — must be set explicitly)"
  type        = list(string)

  validation {
    condition     = length(var.allowed_ssh_cidrs) > 0
    error_message = "At least one CIDR must be specified for SSH access."
  }
}

variable "allowed_api_cidrs" {
  description = "CIDRs allowed to reach the K8s API (no default — must be set explicitly)"
  type        = list(string)

  validation {
    condition     = length(var.allowed_api_cidrs) > 0
    error_message = "At least one CIDR must be specified for K8s API access."
  }
}

variable "allowed_nodeport_cidrs" {
  description = "CIDRs allowed to reach NodePort services (default: none — rule not created)"
  type        = list(string)
  default     = []
}

variable "allowed_icmp_cidrs" {
  description = "CIDRs allowed to send ICMP (default: none — rule not created)"
  type        = list(string)
  default     = []
}

variable "master_public_ip" {
  description = "Assign public IPs to joining masters (master-00 always has a public IP as bastion)"
  type        = bool
  default     = true
}

## ──────────────────────────────────────────────
## Load Balancer
## ──────────────────────────────────────────────
variable "enable_api_lb" {
  description = "Create a load balancer in front of the K8s API"
  type        = bool
  default     = true
}

variable "api_lb_type" {
  description = "Load balancer type"
  type        = string
  default     = "lb11"
}

variable "api_lb_location" {
  description = "Load balancer location"
  type        = string
  default     = "nbg1"
}

## ──────────────────────────────────────────────
## Ingress Load Balancer
## ──────────────────────────────────────────────
variable "enable_ingress_lb" {
  description = "Create a load balancer for ingress (managed by Hetzner CCM)"
  type        = bool
  default     = false
}

variable "ingress_lb_type" {
  description = "Ingress load balancer type"
  type        = string
  default     = "lb11"
}

variable "ingress_lb_location" {
  description = "Ingress load balancer location"
  type        = string
  default     = "nbg1"
}

## ──────────────────────────────────────────────
## Masters
## ──────────────────────────────────────────────
variable "masters" {
  description = "Master node configuration"
  type = object({
    instance_type  = string
    instance_count = number
    location       = string
    image          = optional(string, "ubuntu-24.04")
    labels         = optional(map(string), {})
  })
  default = {
    instance_type  = "cx23"
    instance_count = 1
    location       = "nbg1"
  }

  validation {
    condition     = var.masters.instance_count >= 1 && var.masters.instance_count <= 10
    error_message = "Master instance_count must be between 1 and 10 (Hetzner placement group limit)."
  }

  validation {
    condition     = var.masters.instance_count % 2 == 1
    error_message = "Master instance_count should be odd for etcd quorum (1, 3, 5, ...)."
  }
}

## ──────────────────────────────────────────────
## Workers
## ──────────────────────────────────────────────
variable "worker_pools" {
  description = "Map of worker pool name to pool config"
  type = map(object({
    instance_type  = string
    instance_count = number
    location       = string
    image          = optional(string, "ubuntu-24.04")
    labels         = optional(map(string), {})
    public_ip      = optional(bool, false)
  }))
  default = {
    default = {
      instance_type  = "cx23"
      instance_count = 1
      location       = "nbg1"
    }
  }

  validation {
    condition     = alltrue([for _, pool in var.worker_pools : pool.instance_count >= 1 && pool.instance_count <= 10])
    error_message = "Each worker pool instance_count must be between 1 and 10 (Hetzner placement group limit)."
  }
}

## ──────────────────────────────────────────────
## Storage
## ──────────────────────────────────────────────
variable "enable_local_storage" {
  description = "Enable k3s built-in local-path provisioner (disables need for CSI volumes)"
  type        = bool
  default     = false
}

## ──────────────────────────────────────────────
## Kubernetes add-ons
## ──────────────────────────────────────────────
variable "disable_builtin_cni" {
  description = "Disable k3s built-in flannel CNI and network policy controller (set true when using Cilium, Calico, etc.)"
  type        = bool
  default     = false
}

variable "install_ccm" {
  description = "Install Hetzner Cloud Controller Manager"
  type        = bool
  default     = true
}

variable "install_csi" {
  description = "Install Hetzner CSI driver"
  type        = bool
  default     = true
}

variable "enable_embedded_registry" {
  description = "Enable k3s embedded registry mirror (Spegel) for peer-to-peer image distribution"
  type        = bool
  default     = false
}

variable "ccm_version" {
  description = "Hetzner CCM manifest version"
  type        = string
  default     = "v1.22.0"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.ccm_version))
    error_message = "ccm_version must be a valid semver tag (e.g., v1.22.0)."
  }
}

variable "csi_version" {
  description = "Hetzner CSI manifest version"
  type        = string
  default     = "v2.12.0"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.csi_version))
    error_message = "csi_version must be a valid semver tag (e.g., v2.12.0)."
  }
}

## ──────────────────────────────────────────────
## Protection
## ──────────────────────────────────────────────
variable "enable_delete_protection" {
  description = "Enable delete and rebuild protection on servers and load balancers"
  type        = bool
  default     = false
}

## ──────────────────────────────────────────────
## Misc
## ──────────────────────────────────────────────
variable "kubeconfig_path" {
  description = "Local path to write kubeconfig"
  type        = string
  default     = "./kubeconfig"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_./-]+$", var.kubeconfig_path))
    error_message = "kubeconfig_path must only contain alphanumeric characters, dots, underscores, hyphens, and slashes."
  }
}

variable "dns_servers" {
  description = "DNS servers for nodes"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}
