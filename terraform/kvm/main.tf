locals {
  # /etc/hosts map (hostname -> mgmt IP) for cloud-init, derived from the topology
  # below so it matches whatever deployment is selected.
  hosts = { for h, v in local.inv_hosts : h => v.ansible_host }

  # Default route for lab VMs is the mgmt network gateway (.1 of subnet_mgmt).
  # The monitoring VM is the exception: it routes out via its DHCP external NIC.
  gateway_mgmt = cidrhost(var.subnet_mgmt, 1)

  # ── deployment spec → kvm topology translation ────────────────────────────
  # Read the provider-agnostic spec (roles/count/size/subnets/groups/routes) and
  # translate it into the provider-specific topology the compute module consumes.
  spec = yamldecode(file("${path.root}/../../deployments/${var.deployment}/topology.yml"))

  # t-shirt size class → libvirt memory (MiB) / vCPU (see deployments/README.md).
  size_map = {
    small  = { memory = 4096, vcpu = 2 }
    medium = { memory = 8192, vcpu = 2 }
    large  = { memory = 8192, vcpu = 4 }
    xlarge = { memory = 16384, vcpu = 4 }
  }

  # Spec role → provider role key (identity unless remapped). nl6 runs on netsim.
  provider_role = {
    loadgen = "netsim"
  }

  # Provider role → VM-name prefix ("<prefix>-benchmark-NN").
  role_shortname = {
    database   = "db", core = "core", kafka = "kafka", minion = "minion"
    netsim     = "netsim", monitoring = "mon", elasticsearch = "es"
    sentinel   = "sentinel", mimir = "mimir", victoriametrics = "vm"
    clickhouse = "ch", akvorado = "akvorado", rrd = "rrd"
  }

  subnet_cidr = {
    mgmt  = var.subnet_mgmt
    db    = var.subnet_db
    kafka = var.subnet_kafka
    sim   = var.subnet_sim
  }

  # Per-subnet base IP offset per provider role; node i gets offset + i.
  # Baseline offsets reproduce the current lab.tfvars addresses exactly.
  ip_offset = {
    mgmt  = { database = 4, core = 5, kafka = 6, minion = 7, monitoring = 8, netsim = 9, elasticsearch = 10, sentinel = 11, rrd = 12, mimir = 16, victoriametrics = 24, clickhouse = 40, akvorado = 41 }
    db    = { database = 4, core = 5, elasticsearch = 6, sentinel = 8, mimir = 16, victoriametrics = 24, clickhouse = 40 }
    kafka = { kafka = 4, core = 5, minion = 6, sentinel = 8 }
    sim   = { minion = 5, netsim = 6, clickhouse = 10, akvorado = 11 }
  }

  named_routes = {
    net_sim = { to = var.net_sim_cidr, via = var.net_sim_gateway }
  }

  # Expand each spec role into `count` nodes, keyed by provider role (+ -N when >1).
  nodes = merge([
    for srole, cfg in local.spec.roles : {
      for i in range(try(cfg.count, 1)) :
      "${lookup(local.provider_role, srole, srole)}${try(cfg.count, 1) > 1 ? "-${i}" : ""}" => {
        prole = lookup(local.provider_role, srole, srole)
        index = i
        cfg   = cfg
      }
    }
  ]...)

  topology = {
    for key, n in local.nodes :
    key => {
      vm_name = "${local.role_shortname[n.prole]}-benchmark-${format("%02d", n.index + 1)}"
      memory  = local.size_map[n.cfg.size].memory
      vcpu    = local.size_map[n.cfg.size].vcpu
      disk_gb = lookup(var.disk_sizes_gb, n.prole, 30)
      interfaces = [
        for si, subnet in n.cfg.subnets : {
          subnet     = subnet
          iface_name = "enp${si + 1}s0"
          address    = subnet == "external" ? null : cidrhost(local.subnet_cidr[subnet], local.ip_offset[subnet][n.prole] + n.index)
          prefix     = subnet == "external" ? null : 26
          gateway    = (subnet == "mgmt" && !try(n.cfg.public_ip, false)) ? local.gateway_mgmt : null
          routes     = try(n.cfg.routes[subnet], null) != null ? [local.named_routes[n.cfg.routes[subnet]]] : []
        }
      ]
    }
  }

  # ── inventory data derived from the topology ──────────────────────────────
  # hostname -> ansible_host (mgmt IP), inventory groups, and host vars.
  inv_hosts = {
    for key, n in local.nodes :
    local.topology[key].vm_name => {
      # mgmt NIC address; "" if a role has no mgmt subnet (caught by the inventory
      # module precondition with a clear message rather than a cryptic index error).
      ansible_host = try([for i in local.topology[key].interfaces : i.address if i.subnet == "mgmt"][0], "")
      groups       = try(n.cfg.groups, [])
      # nl6 runs on the netsim host; expose its sim NIC name for the generator.
      host_vars = n.prole == "netsim" ? {
        nl6_net_interface = try([for i in local.topology[key].interfaces : i.iface_name if i.subnet == "sim"][0], "")
      } : {}
    }
  }

  # The jump host is the public_ip node (its external DHCP IP is var.jump_host).
  # one() errors if a spec marks more than one node public_ip; null if none.
  jump_node_key  = one([for key, n in local.nodes : key if try(n.cfg.public_ip, false)])
  jump_host_name = local.jump_node_key != null ? local.topology[local.jump_node_key].vm_name : ""

  # Canonical opennms_stack membership. TSDB/flow backends (mimir, victoriametrics,
  # clickhouse, akvorado) are intentionally excluded — OpenNMS writes to them; they
  # are not orchestrated as part of the stack group. Children absent from the
  # selected deployment are dropped by the inventory module.
  onms_stack_children = ["database", "core", "message_broker", "elasticsearch", "minion", "sentinel", "grafana"]
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
  source = "../modules/topology-inventory"

  hosts          = local.inv_hosts
  admin_user     = var.admin_user
  ssh_key_path   = var.ssh_key_path
  jump_host      = var.jump_host
  jump_host_name = local.jump_host_name
  parent_groups  = { opennms_stack = local.onms_stack_children }
}
