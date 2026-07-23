locals {
  hosts = {
    "db-benchmark-01"     = var.ip_database
    "core-benchmark-01"   = var.ip_core
    "kafka-benchmark-01"  = var.ip_kafka
    "minion-benchmark-01" = var.ip_minion
    "netsim-benchmark-01" = var.ip_netsim
    "mon-benchmark-01"    = var.ip_monitoring
    "es-benchmark-01"     = var.ip_elasticsearch
  }

  # Default route for lab VMs is the mgmt network gateway (.1 of subnet_mgmt).
  # The monitoring VM is the exception: it routes out via its DHCP external NIC.
  gateway_mgmt = cidrhost(var.subnet_mgmt, 1)

  # Topology spec (keyed by role): the deployment-under-test as data. Node count
  # is 1 per role today; interface addresses/gateways/sizes are the current
  # values, so this refactor is byte-for-byte identical in plan. One interfaces
  # list per role drives both cloud-init network-config and the domain NICs.
  topology = {
    elasticsearch = {
      vm_name = "es-benchmark-01"
      memory  = 8192
      vcpu    = 4
      interfaces = [
        { subnet = "mgmt", iface_name = "enp1s0", address = var.ip_elasticsearch, prefix = 26, gateway = local.gateway_mgmt },
        { subnet = "db", iface_name = "enp2s0", address = var.ip_es_core, prefix = 26, gateway = null },
      ]
    }
    database = {
      vm_name = "db-benchmark-01"
      memory  = 4096
      vcpu    = 2
      interfaces = [
        { subnet = "mgmt", iface_name = "enp1s0", address = var.ip_database, prefix = 26, gateway = local.gateway_mgmt },
        { subnet = "db", iface_name = "enp2s0", address = var.ip_database_db, prefix = 26, gateway = null },
      ]
    }
    core = {
      vm_name = "core-benchmark-01"
      memory  = 16384
      vcpu    = 4
      interfaces = [
        { subnet = "mgmt", iface_name = "enp1s0", address = var.ip_core, prefix = 26, gateway = local.gateway_mgmt },
        { subnet = "db", iface_name = "enp2s0", address = var.ip_core_db, prefix = 26, gateway = null },
        { subnet = "kafka", iface_name = "enp3s0", address = var.ip_core_kafka, prefix = 26, gateway = null },
      ]
    }
    kafka = {
      vm_name = "kafka-benchmark-01"
      memory  = 4096
      vcpu    = 2
      interfaces = [
        { subnet = "mgmt", iface_name = "enp1s0", address = var.ip_kafka, prefix = 26, gateway = local.gateway_mgmt },
        { subnet = "kafka", iface_name = "enp2s0", address = var.ip_kafka_kafka, prefix = 26, gateway = null },
      ]
    }
    minion = {
      vm_name = "minion-benchmark-01"
      memory  = 4096
      vcpu    = 2
      interfaces = [
        { subnet = "mgmt", iface_name = "enp1s0", address = var.ip_minion, prefix = 26, gateway = local.gateway_mgmt },
        { subnet = "kafka", iface_name = "enp2s0", address = var.ip_minion_kafka, prefix = 26, gateway = null },
        { subnet = "sim", iface_name = "enp3s0", address = var.ip_minion_sim, prefix = 26, gateway = null, routes = [{ to = var.net_sim_cidr, via = var.net_sim_gateway }] },
      ]
    }
    netsim = {
      vm_name = "netsim-benchmark-01"
      memory  = 4096
      vcpu    = 2
      interfaces = [
        { subnet = "mgmt", iface_name = "enp1s0", address = var.ip_netsim, prefix = 26, gateway = local.gateway_mgmt },
        { subnet = "sim", iface_name = "enp2s0", address = var.ip_netsim_sim, prefix = 26, gateway = null },
      ]
    }
    monitoring = {
      vm_name = "mon-benchmark-01"
      memory  = 4096
      vcpu    = 2
      interfaces = [
        { subnet = "mgmt", iface_name = "enp1s0", address = var.ip_monitoring, prefix = 26, gateway = null },
        { subnet = "external", iface_name = "enp2s0", address = null, prefix = null, gateway = null },
      ]
    }
  }
}

module "network" {
  source = "./modules/network"

  subnet_db    = var.subnet_db
  subnet_kafka = var.subnet_kafka
  subnet_sim   = var.subnet_sim
  subnet_mgmt  = var.subnet_mgmt
  bridge_name  = var.bridge_name
}

module "compute" {
  source = "./modules/compute"

  storage_pool        = var.storage_pool
  ubuntu_cloud_image  = var.ubuntu_cloud_image
  admin_user          = var.admin_user
  ssh_public_key      = trimspace(file(pathexpand("${var.ssh_key_path}.pub")))
  hosts               = local.hosts
  network_db_id       = module.network.network_db_id
  network_kafka_id    = module.network.network_kafka_id
  network_sim_id      = module.network.network_sim_id
  network_mgmt_id     = module.network.network_mgmt_id
  network_external_id = module.network.network_external_id
  disk_sizes_gb       = var.disk_sizes_gb
  topology            = local.topology
}

module "diagram" {
  source = "../modules/diagram"

  subnet_mgmt  = var.subnet_mgmt
  subnet_db    = var.subnet_db
  subnet_kafka = var.subnet_kafka
  subnet_sim   = var.subnet_sim

  ip_monitoring    = var.ip_monitoring
  ip_database      = var.ip_database
  ip_core          = var.ip_core
  ip_kafka         = var.ip_kafka
  ip_minion        = var.ip_minion
  ip_netsim        = var.ip_netsim
  ip_elasticsearch = var.ip_elasticsearch

  ip_database_db  = var.ip_database_db
  ip_core_db      = var.ip_core_db
  ip_es_core      = var.ip_es_core
  ip_kafka_kafka  = var.ip_kafka_kafka
  ip_core_kafka   = var.ip_core_kafka
  ip_minion_kafka = var.ip_minion_kafka
  ip_minion_sim   = var.ip_minion_sim
  ip_netsim_sim   = var.ip_netsim_sim

  vm_names = var.vm_names
}

module "inventory" {
  source = "../modules/inventory"

  ip_database          = var.ip_database
  ip_core              = var.ip_core
  ip_kafka             = var.ip_kafka
  ip_minion            = var.ip_minion
  ip_netsim            = var.ip_netsim
  ip_monitoring        = var.ip_monitoring
  ip_elasticsearch     = var.ip_elasticsearch
  admin_user           = var.admin_user
  ssh_key_path         = var.ssh_key_path
  jump_host            = var.jump_host
  netsim_sim_interface = "enp2s0"
}
