variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH into the cluster nodes"
  type        = list(string)
}

variable "allowed_api_cidrs" {
  description = "CIDRs allowed to reach the K8s API"
  type        = list(string)
}

variable "cluster_name" {
  description = "Cluster name prefix for all resources"
  type        = string
  default     = "dev"
}

variable "masters" {
  description = "Master configuration (override for testing)"
  type = object({
    instance_type  = string
    instance_count = number
    location       = string
  })
  default = {
    instance_type  = "cx23"
    instance_count = 1
    location       = "nbg1"
  }
}

variable "worker_pools" {
  description = "Worker pool configuration (override for testing)"
  type = map(object({
    instance_type  = string
    instance_count = number
    location       = string
  }))
  default = {
    default = {
      instance_type  = "cx23"
      instance_count = 1
      location       = "nbg1"
    }
  }
}

variable "disable_builtin_cni" {
  description = "Disable k3s built-in flannel CNI (for BYO CNI like Cilium)"
  type        = bool
  default     = false
}

variable "enable_api_lb" {
  description = "Enable API load balancer (required for private masters)"
  type        = bool
  default     = false
}

variable "master_public_ip" {
  description = "Assign public IPs to joining masters"
  type        = bool
  default     = true
}

variable "api_lb_type" {
  description = "API load balancer type"
  type        = string
  default     = "lb11"
}

variable "api_lb_location" {
  description = "API load balancer location"
  type        = string
  default     = "nbg1"
}

variable "enable_embedded_registry" {
  description = "Enable k3s embedded container registry mirror"
  type        = bool
  default     = false
}

variable "enable_ingress_lb" {
  description = "Enable ingress load balancer"
  type        = bool
  default     = false
}
