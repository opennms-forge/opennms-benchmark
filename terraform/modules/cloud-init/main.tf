locals {
  network_config = templatefile("${path.module}/templates/network-config.yaml.tftpl", {
    interfaces = var.interfaces
  })

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    vm_name        = var.vm_name
    admin_user     = var.admin_user
    ssh_public_key = var.ssh_public_key
    hosts          = var.hosts
    extra_packages = var.extra_packages
    local_routes   = var.local_routes
  })
}
