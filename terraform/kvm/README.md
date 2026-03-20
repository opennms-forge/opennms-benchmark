# KVM Terraform Root

Deploys the OpenNMS benchmark lab on a KVM/libvirt host.

## Prerequisites

### 1. Ubuntu 24.04 LTS Cloud Image

Download the cloud image (not the server installer ISO) into the libvirt storage pool before running `terraform apply`:

```bash
wget -O /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

The path must match `ubuntu_cloud_image` in `kvm.tfvars`. Terraform will fail with a clear error if the file is missing.

### 2. Libvirt storage pool

Ensure the `default` storage pool exists and is active:

```bash
virsh pool-list --all
virsh pool-start default   # if inactive
```

### 3. SSH key

```bash
export TF_VAR_ssh_public_key=$(cat ~/.ssh/id_rsa.pub)
```

## Deploy

```bash
cd terraform/kvm
terraform init
terraform apply -var-file=../lab.tfvars -var-file=kvm.tfvars
```

## Deploying to a Remote KVM Host

By default, `kvm.tfvars` connects to the local KVM daemon:

```hcl
libvirt_uri = "qemu:///system"
```

To deploy to a **remote** KVM host, change this to an SSH URI:

```hcl
libvirt_uri = "qemu+ssh://user@your-kvm-host/system"
```

The `dmacvicar/libvirt` provider uses libvirt's native transport layer, so no additional Terraform plugins are required.

### Prerequisites on the remote KVM host

1. **libvirtd running**

   ```bash
   sudo systemctl enable --now libvirtd
   ```

2. **Your user in the `libvirt` group**

   ```bash
   sudo usermod -aG libvirt $USER
   # Log out and back in for the group change to take effect
   ```

3. **SSH access** — the connecting user must be able to SSH to the host without a passphrase prompt. Load your key into the SSH agent on your local machine:

   ```bash
   ssh-add ~/.ssh/id_rsa
   ```

4. **Ubuntu 24.04 LTS cloud image** on the remote host, at the path specified by `ubuntu_cloud_image` in `kvm.tfvars`:

   ```bash
   sudo wget -O /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
     https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
   ```

5. **libvirt default storage pool** active on the remote host:

   ```bash
   virsh -c qemu+ssh://user@your-kvm-host/system pool-list --all
   virsh -c qemu+ssh://user@your-kvm-host/system pool-start default   # if inactive
   ```

### Remote-specific `kvm.tfvars`

Create a separate var file (e.g., `kvm-remote.tfvars`) to avoid editing the defaults:

```hcl
libvirt_uri        = "qemu+ssh://user@your-kvm-host/system"
ubuntu_cloud_image = "/var/lib/libvirt/images/noble-server-cloudimg-amd64.img"
storage_pool       = "default"
ssh_key_path       = "~/.ssh/id_rsa"
admin_user         = "ubuntu"
```

All paths in `kvm.tfvars` (storage pool, cloud image) are resolved **on the remote host**, not your local machine.

### Deploy to the remote host

```bash
cd terraform/kvm
terraform init
terraform apply -var-file=../lab.tfvars -var-file=kvm.tfvars -var-file=kvm-remote.tfvars
```

### Verify connectivity before applying

Test that Terraform can reach libvirtd on the remote host before running `apply`:

```bash
virsh -c qemu+ssh://user@your-kvm-host/system list --all
```

A successful response (even an empty VM list) confirms the connection works.

## Network Quality Note

All 6 VMs must be connected by a network sufficient to avoid introducing artificial latency into benchmark measurements. On a single KVM host this is inherent. On a multi-host KVM cluster, ensure VMs are placed on the same physical host or connected via a low-latency fabric.
