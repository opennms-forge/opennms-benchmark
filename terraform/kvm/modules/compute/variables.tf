variable "storage_pool" { type = string }
variable "ubuntu_cloud_image" { type = string }
variable "admin_user" { type = string }
variable "ssh_public_key" {
  type      = string
  sensitive = true
}
variable "hosts" { type = map(string) }
variable "extra_packages" {
  type    = list(string)
  default = ["qemu-guest-agent"]
}

variable "network_db_id" { type = string }
variable "network_kafka_id" { type = string }
variable "network_sim_id" { type = string }
variable "network_mgmt_id" { type = string }
variable "network_external_id" { type = string }

variable "disk_sizes_gb" {
  type        = map(number)
  description = "Disk size in GB per role (keyed by topology role name)"
  default = {
    database      = 50
    core          = 100
    kafka         = 50
    minion        = 20
    netsim        = 20
    monitoring    = 30
    elasticsearch = 50
  }
}

# Topology spec (keyed by role); see terraform/kvm/main.tf for the schema. One
# interfaces list per role drives both the cloud-init network-config and the
# libvirt_domain network interfaces (in the same order).
variable "topology" {
  type = map(object({
    vm_name = string
    memory  = number
    vcpu    = number
    interfaces = list(object({
      subnet     = string
      iface_name = string
      address    = optional(string)
      prefix     = optional(number)
      gateway    = optional(string)
      routes     = optional(list(object({ to = string, via = string })), [])
    }))
  }))
}
