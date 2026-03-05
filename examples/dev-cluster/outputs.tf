output "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  value       = module.k3s.kubeconfig_path
}

output "api_endpoint" {
  description = "K8s API endpoint URL"
  value       = module.k3s.api_endpoint
}

output "ssh_command" {
  description = "SSH command to connect to master-00"
  value       = module.k3s.ssh_command
}

output "network_id" {
  description = "Private network ID"
  value       = module.k3s.network_id
}

output "master_ips" {
  description = "Master public IPs"
  value       = module.k3s.master_ips
}

output "master_private_ips" {
  description = "Master private IPs"
  value       = module.k3s.master_private_ips
}

output "worker_ips" {
  description = "Worker IPs"
  value       = module.k3s.worker_ips
}

output "worker_private_ips" {
  description = "Worker private IPs"
  value       = module.k3s.worker_private_ips
}

output "load_balancer_ip" {
  description = "API load balancer IP"
  value       = module.k3s.load_balancer_ip
}

output "ingress_lb_ip" {
  description = "Ingress load balancer IP"
  value       = module.k3s.ingress_lb_ip
}
