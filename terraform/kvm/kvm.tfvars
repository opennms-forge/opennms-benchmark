# KVM-specific variables
libvirt_uri        = "qemu+ssh://root@mad-monkey.labmonkeys.tech/system" # Remote: "qemu+ssh://user@host/system"
storage_pool       = "default"
ubuntu_cloud_image = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
ssh_public_key     = "" # Set via: export TF_VAR_ssh_public_key=$(cat ~/.ssh/id_rsa.pub)
ssh_key_path       = "~/.ssh/id_rsa"
admin_user         = "ubuntu" # Ubuntu cloud image default user
bridge_name        = "br0"   # Host bridge for external DHCP access on mon VM
