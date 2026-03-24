output "libvirt_host" {
  value       = regex("@([^/]+)/", var.libvirt_uri)[0]
  description = "Hostname of the KVM/libvirt host, extracted from libvirt_uri"
}

output "ip_monitoring" {
  value       = var.ip_monitoring
  description = "Management IP of the monitoring VM (reachable from the KVM host via NAT)"
}

output "admin_user" {
  value       = var.admin_user
  description = "Admin user on the VMs"
}
