output "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  value       = var.kubeconfig_path
}

output "kubeconfig_content" {
  description = "Kubeconfig file content (stored in state, for CI/CD retrieval)"
  value       = data.external.kubeconfig_content.result.content
  sensitive   = true
}

output "api_endpoint" {
  description = "K8s API endpoint (LB IP or master-00 IP)"
  value       = "https://${local.api_endpoint}:6443"
}

output "master_ips" {
  description = "Map of master name to public IPv4 (or private IP for joining masters if master_public_ip is false)"
  value = merge(
    { (local.master_init_key) = hcloud_server.master_init.ipv4_address },
    { for k, v in hcloud_server.masters : k =>
      var.master_public_ip ? v.ipv4_address : one(v.network).ip
    }
  )
}

output "master_private_ips" {
  description = "Map of master name to private IP"
  value = merge(
    { (local.master_init_key) = one(hcloud_server.master_init.network).ip },
    { for k, v in hcloud_server.masters : k => one(v.network).ip }
  )
}

output "worker_ips" {
  description = "Map of worker name to public IPv4 (or private IP if public_ip is false for that pool)"
  value = {
    for k, v in hcloud_server.workers : k =>
    local.worker_map[k].public_ip ? v.ipv4_address : one(v.network).ip
  }
}

output "worker_private_ips" {
  description = "Map of worker name to private IP"
  value       = { for k, v in hcloud_server.workers : k => one(v.network).ip }
}

output "load_balancer_ip" {
  description = "API load balancer IPv4 (empty if disabled)"
  value       = var.enable_api_lb ? hcloud_load_balancer.api[0].ipv4 : ""
}

output "ingress_lb_ip" {
  description = "Ingress load balancer IPv4 (empty if disabled)"
  value       = var.enable_ingress_lb ? hcloud_load_balancer.ingress[0].ipv4 : ""
}

output "ingress_lb_name" {
  description = "Ingress load balancer name (empty if disabled)"
  value       = var.enable_ingress_lb ? hcloud_load_balancer.ingress[0].name : ""
}

output "network_id" {
  description = "Private network ID"
  value       = hcloud_network.cluster.id
}

output "ssh_private_key" {
  description = "SSH private key (extract with: tofu output -raw ssh_private_key > key && chmod 600 key)"
  value       = tls_private_key.cluster.private_key_openssh
  sensitive   = true
}

output "ssh_command" {
  description = "SSH to master-00 (after extracting the key)"
  value       = "ssh -i <key-file> -p ${var.ssh_port} root@${hcloud_server.master_init.ipv4_address}"
}
