output "proxmox_endpoint" {
  value       = var.proxmox_endpoint
  description = "Proxmox VE API endpoint"
}

output "ip_monitoring" {
  value       = var.ip_monitoring
  description = "Management IP of the monitoring VM"
}

output "admin_user" {
  value       = var.admin_user
  description = "Admin user on the VMs"
}
