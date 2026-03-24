# Azure-specific variables
location       = "eastus"
environment    = "prod"
project_name   = "benchmark"
vm_size_small  = "Standard_B2ms"
vm_size_medium = "Standard_B4ms"
priority       = "Regular" # Regular or Spot
operator_cidr  = ""        # Set to your public IP: e.g. "203.0.113.5/32"
ssh_key_path   = "~/.ssh/id_rsa"
