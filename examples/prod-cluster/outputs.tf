output "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  value       = module.k3s.kubeconfig_path
}

output "api_endpoint" {
  description = "K8s API endpoint URL"
  value       = module.k3s.api_endpoint
}

output "load_balancer_ip" {
  description = "API load balancer IPv4"
  value       = module.k3s.load_balancer_ip
}

output "master_ips" {
  description = "Map of master name to IP"
  value       = module.k3s.master_ips
}

output "worker_ips" {
  description = "Map of worker name to IP"
  value       = module.k3s.worker_ips
}

output "ssh_command" {
  description = "SSH command to connect to master-00"
  value       = module.k3s.ssh_command
}
