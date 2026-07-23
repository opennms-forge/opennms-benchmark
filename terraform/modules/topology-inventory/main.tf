terraform {
  required_version = ">= 1.5"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

locals {
  # Union of all group names across hosts.
  all_groups = sort(distinct(flatten([for h, n in var.hosts : n.groups])))

  # group -> sorted member hostnames.
  group_members = {
    for g in local.all_groups :
    g => sort([for h, n in var.hosts : h if contains(n.groups, g)])
  }

  # Parent groups, with children filtered to those actually present.
  parent_present = {
    for p, children in var.parent_groups :
    p => [for c in children : c if contains(local.all_groups, c)]
    if length([for c in children : c if contains(local.all_groups, c)]) > 0
  }
}

resource "local_file" "ansible_inventory" {
  filename = "${path.root}/../../ansible-inventory.yml"
  content = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    hosts          = var.hosts
    admin_user     = var.admin_user
    ssh_key_path   = var.ssh_key_path
    jump_host      = var.jump_host
    jump_host_name = var.jump_host_name
    group_members  = local.group_members
    parent_groups  = local.parent_present
  })
}
