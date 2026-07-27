#!/usr/bin/env bash
# deploy.sh — provision lab infrastructure and deploy OpenNMS Horizon
#
# Workflow:
#   1. terraform apply             — creates VMs and writes ansible-inventory.yml
#   2. ansible-playbook bootstrap  — installs base tooling
#   3. ansible-galaxy collection install — pulls indigo423.opennms and friends
#   4. ansible-playbook opennms    — deploys OpenNMS stack
#
# For KVM and Proxmox the monitoring VM gets a DHCP address on an external
# bridge.  The script SSH-probes that address after the first apply, then
# re-runs apply with -var jump_host=<ip> so the inventory is correct.
#
set -euo pipefail

# ── helpers ───────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 --provider <azure|kvm|proxmox|vmware> [OPTIONS]

Options:
  --provider   <azure|kvm|proxmox|vmware>  Target infrastructure provider (required)
  --deployment <slug>               Deployment topology from deployments/<slug>/ (kvm; default baseline)
  --destroy                         Tear down all lab resources
  --tf-args    "<args>"             Extra arguments passed verbatim to terraform
  -v|-vv|-vvv|-vvvv                 Ansible verbosity
  -h|--help                         Show this message

Examples:
  $0 --provider azure
  $0 --provider kvm
  $0 --provider kvm --deployment mimir-single
  $0 --provider proxmox
  $0 --provider vmware
  $0 --provider azure --destroy
  $0 --provider proxmox --tf-args "-var proxmox_insecure=true"
  $0 --provider vmware --tf-args "-var vsphere_insecure=true"
  $0 --provider kvm -vvv
EOF
}

# Print usage to stderr and exit non-zero (used on bad arguments).
error_usage() { usage >&2; exit 1; }

step() { echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "    warning: $*" >&2; }

# ── argument parsing ──────────────────────────────────────────────────────────

PROVIDER=""
DESTROY=false
TF_EXTRA_ARGS=()
ANSIBLE_VERBOSITY=""
DEPLOYMENT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --provider)   PROVIDER="$2"; shift 2 ;;
    --deployment) DEPLOYMENT="${2:?--deployment requires a value}"; shift 2 ;;
    --destroy)    DESTROY=true; shift ;;
    --tf-args)    read -ra TF_EXTRA_ARGS <<< "$2"; shift 2 ;;
    -v|-vv|-vvv|-vvvv) ANSIBLE_VERBOSITY="$1"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; error_usage ;;
  esac
done

[[ -z "$PROVIDER" ]] && { echo "Error: --provider is required" >&2; error_usage; }
case "$PROVIDER" in
  azure|kvm|proxmox|vmware) ;;
  *) echo "Error: provider must be 'azure', 'kvm', 'proxmox', or 'vmware'" >&2; error_usage ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform/$PROVIDER"
TFVARS_FILE="$TF_DIR/${PROVIDER}.tfvars"

# lab.tfvars is provider-agnostic; disk-sizes.tfvars applies to kvm, proxmox, and vmware only.
COMMON_VAR_FILES=(-var-file="../lab.tfvars")
if [[ "$PROVIDER" == "kvm" || "$PROVIDER" == "proxmox" || "$PROVIDER" == "vmware" ]]; then
  [[ -f "$REPO_ROOT/terraform/disk-sizes.tfvars" ]] || { echo "Error: terraform/disk-sizes.tfvars not found" >&2; exit 1; }
  COMMON_VAR_FILES+=(-var-file="../disk-sizes.tfvars")
fi

if [[ ! -f "$TFVARS_FILE" ]]; then
  echo "Error: $TFVARS_FILE not found." >&2
  echo "       Copy ${TFVARS_FILE}.example → $TFVARS_FILE and fill in your values." >&2
  exit 1
fi

# Deployment selection: the `deployment` Terraform variable is declared only on
# spec-driven providers (kvm today). The matching Ansible config overlay
# (deployments/<slug>/opennms-lab-vars.yml) is layered onto the OpenNMS play.
DEPLOYMENT_VARS=()
if [[ -n "$DEPLOYMENT" && "$PROVIDER" == "kvm" ]]; then
  DEPLOYMENT_VARS=(-var "deployment=$DEPLOYMENT")
fi
DEPLOYMENT_VARS_FILE=""
if [[ -n "$DEPLOYMENT" && "$PROVIDER" == "kvm" && -f "$REPO_ROOT/deployments/$DEPLOYMENT/opennms-lab-vars.yml" ]]; then
  DEPLOYMENT_VARS_FILE="--extra-vars=@$REPO_ROOT/deployments/$DEPLOYMENT/opennms-lab-vars.yml"
fi

# ── provider-specific extra vars ──────────────────────────────────────────────

# Populate PROVIDER_VARS array with extra -var flags needed for this provider.
# Azure: detect the operator's public IP for the NSG SSH-allow rule.
PROVIDER_VARS=()

set_provider_vars() {
  PROVIDER_VARS=()
  if [[ "$PROVIDER" == "azure" ]]; then
    local op_ip
    op_ip=$(host -4 myip.opendns.com resolver1.opendns.com 2>/dev/null \
            | awk '/has address/ {print $NF; exit}' || true)
    if [[ -n "$op_ip" ]]; then
      info "detected operator IP: $op_ip"
      PROVIDER_VARS=(-var "operator_cidr=${op_ip}/32")
    else
      warn "could not detect public IP; SSH access on monitoring VM will be open to *"
    fi
  fi
}

# SSH through the hypervisor to the monitoring VM's management IP and return
# the first non-internal IPv4 address (the DHCP external bridge address).
# Retries for up to 2 minutes.
discover_jump_host() {
  local hypervisor="$1" mgmt_ip="$2" admin_user="$3"
  local jump_host=""
  for i in $(seq 1 24); do
    jump_host=$(ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o ProxyJump="$hypervisor" \
      "${admin_user}@${mgmt_ip}" \
      'ip -4 addr | grep inet | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | grep -v "^192\.0\.2\.\|^127\."' \
      2>/dev/null | head -1 || true)
    [[ -n "$jump_host" ]] && break
    info "waiting for external IP on monitoring VM... ($i/24)" >&2
    sleep 5
  done
  echo "$jump_host"
}

# ── terraform wrappers ────────────────────────────────────────────────────────

tf_init() {
  terraform -chdir="$TF_DIR" init -upgrade -input=false
}

tf_apply() {
  terraform -chdir="$TF_DIR" apply \
    "${COMMON_VAR_FILES[@]}" \
    -var-file="${PROVIDER}.tfvars" \
    "${DEPLOYMENT_VARS[@]+"${DEPLOYMENT_VARS[@]}"}" \
    "$@" \
    "${TF_EXTRA_ARGS[@]+"${TF_EXTRA_ARGS[@]}"}" \
    -input=false \
    -auto-approve
}

tf_destroy() {
  terraform -chdir="$TF_DIR" destroy \
    "${COMMON_VAR_FILES[@]}" \
    -var-file="${PROVIDER}.tfvars" \
    "${DEPLOYMENT_VARS[@]+"${DEPLOYMENT_VARS[@]}"}" \
    "$@" \
    "${TF_EXTRA_ARGS[@]+"${TF_EXTRA_ARGS[@]}"}" \
    -input=false \
    -auto-approve
}

tf_output() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true
}

# ── destroy path ──────────────────────────────────────────────────────────────

if $DESTROY; then
  step "Destroying infrastructure ($PROVIDER)..."
  tf_init
  set_provider_vars
  tf_destroy "${PROVIDER_VARS[@]+"${PROVIDER_VARS[@]}"}"
  rm -f "$REPO_ROOT/ansible-inventory.yml"
  step "Done. All $PROVIDER lab resources destroyed."
  exit 0
fi

# ── deploy path ───────────────────────────────────────────────────────────────

step "[1/3] Provisioning infrastructure ($PROVIDER)..."
tf_init
set_provider_vars
tf_apply "${PROVIDER_VARS[@]+"${PROVIDER_VARS[@]}"}"

# KVM and Proxmox: the monitoring VM's external (jump host) IP is DHCP-assigned
# after boot and cannot be known at plan time.  Discover it via SSH through the
# hypervisor, then re-apply to regenerate the Ansible inventory with ProxyJump.
if [[ "$PROVIDER" == "kvm" || "$PROVIDER" == "proxmox" || "$PROVIDER" == "vmware" ]]; then
  IP_MONITORING=$(tf_output ip_monitoring)
  ADMIN_USER=$(tf_output admin_user)

  if [[ "$PROVIDER" == "kvm" ]]; then
    HYPERVISOR=$(tf_output libvirt_host)
  elif [[ "$PROVIDER" == "proxmox" ]]; then
    # Proxmox: derive SSH host from the API endpoint URL.
    PROXMOX_ENDPOINT=$(tf_output proxmox_endpoint)
    HYPERVISOR=$(echo "$PROXMOX_ENDPOINT" | sed 's|https\?://||; s|[:/].*||')
  else
    # VMware: SSH directly to the ESXi host (or vCenter) to probe the monitoring VM.
    HYPERVISOR=$(tf_output vsphere_server)
  fi

  if [[ -n "$HYPERVISOR" && -n "$IP_MONITORING" ]]; then
    step "Discovering monitoring VM external IP (via $HYPERVISOR → $IP_MONITORING)..."
    JUMP_HOST=$(discover_jump_host "$HYPERVISOR" "$IP_MONITORING" "$ADMIN_USER")

    if [[ -n "$JUMP_HOST" ]]; then
      info "found: $JUMP_HOST — regenerating inventory with jump host..."
      tf_apply "${PROVIDER_VARS[@]+"${PROVIDER_VARS[@]}"}" -var "jump_host=$JUMP_HOST"
    else
      warn "could not discover external IP after 2 minutes; jump host not configured"
    fi
  fi
fi

step "[2/4] Bootstrapping VMs..."
# shellcheck disable=SC2086
ansible-playbook \
  --become \
  -i "$REPO_ROOT/ansible-inventory.yml" \
  $ANSIBLE_VERBOSITY \
  "$REPO_ROOT/bootstrap/site.yml"

step "[3/4] Installing Ansible Galaxy collections..."
ansible-galaxy collection install \
  -r "$REPO_ROOT/requirements.yml" \
  --force-with-deps

# A deployment may ship its own playbook when it stands up a different stack.
# Deployment H (clickhouse-akvorado) deploys no OpenNMS at all, so bolting its
# plays into opennms-playbook.yml would hide a second stack inside a playbook
# named for the first. Every OpenNMS deployment ships no playbook.yml and gets
# the shared one, which keeps its play order — the stack's dependency graph —
# in exactly one place.
# Gated on kvm for the same reason as the vars overlay above: only kvm is
# spec-driven, so on other providers --deployment does not shape the infra and
# a per-deployment playbook would target hosts that were never provisioned.
DEPLOYMENT_PLAYBOOK="$REPO_ROOT/opennms-playbook.yml"
STACK_LABEL="OpenNMS Horizon"
if [[ -n "$DEPLOYMENT" && "$PROVIDER" == "kvm" && -f "$REPO_ROOT/deployments/$DEPLOYMENT/playbook.yml" ]]; then
  DEPLOYMENT_PLAYBOOK="$REPO_ROOT/deployments/$DEPLOYMENT/playbook.yml"
  STACK_LABEL="$DEPLOYMENT stack"
fi

step "[4/4] Deploying $STACK_LABEL..."
# shellcheck disable=SC2086
ansible-playbook \
  --become \
  -i "$REPO_ROOT/ansible-inventory.yml" \
  $ANSIBLE_VERBOSITY \
  "$DEPLOYMENT_PLAYBOOK" \
  --extra-vars="@$REPO_ROOT/opennms-lab-vars.yml" \
  $DEPLOYMENT_VARS_FILE
