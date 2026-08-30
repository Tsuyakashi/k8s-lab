output "vnet_id" {
  description = "Consumed by env/nodes via terraform_remote_state."
  value       = module.k8s_cp_network.vnet_id
}

output "subnet_gateway" {
  value = module.k8s_cp_network.subnet_gateway
}
