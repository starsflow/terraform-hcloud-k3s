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
