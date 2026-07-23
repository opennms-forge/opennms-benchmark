variable "hosts" {
  description = "Hostname -> { ansible_host, groups, host_vars } derived from the topology."
  type = map(object({
    ansible_host = string
    groups       = list(string)
    host_vars    = optional(map(string), {})
  }))
}

variable "parent_groups" {
  description = "Parent group -> child group names. Children not present in `hosts` are dropped."
  type        = map(list(string))
  default     = {}
}

variable "admin_user" { type = string }
variable "ssh_key_path" { type = string }

variable "jump_host" {
  type        = string
  default     = ""
  description = "External IP of the jump host; when set, the jump host is reached directly and others via ProxyCommand."
}

variable "jump_host_name" {
  type        = string
  default     = ""
  description = "Hostname (in `hosts`) that is the jump host."
}
