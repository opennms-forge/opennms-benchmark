#!/usr/bin/env bash
# deploy.sh — provision infrastructure and bootstrap all VMs, or tear it down
#
# Usage:
#   ./deploy.sh --provider <azure|kvm> [--destroy] [--tf-args "<extra terraform args>"] [-v|-vv|-vvv|-vvvv]
#
# Examples:
#   ./deploy.sh --provider azure
#   ./deploy.sh --provider kvm
#   ./deploy.sh --provider azure --destroy
#   ./deploy.sh --provider azure --tf-args "-var 'operator_cidr=1.2.3.4/32'"
#   ./deploy.sh --provider kvm -vvv

set -euo pipefail

usage() {
  echo "Usage: $0 --provider <azure|kvm> [--destroy] [--tf-args <extra terraform args>] [-v|-vv|-vvv|-vvvv]"
  exit 1
}

PROVIDER=""
DESTROY=false
TF_EXTRA_ARGS=""
ANSIBLE_VERBOSITY=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --provider) PROVIDER="$2"; shift 2 ;;
    --destroy)  DESTROY=true; shift ;;
    --tf-args)  TF_EXTRA_ARGS="$2"; shift 2 ;;
    -v|-vv|-vvv|-vvvv) ANSIBLE_VERBOSITY="$1"; shift ;;
    *) usage ;;
  esac
done

[[ -z "$PROVIDER" ]] && usage
[[ "$PROVIDER" != "azure" && "$PROVIDER" != "kvm" ]] && { echo "Error: provider must be 'azure' or 'kvm'"; usage; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform/$PROVIDER"

if $DESTROY; then
  echo "==> Destroying infrastructure ($PROVIDER)..."
  cd "$TF_DIR"
  # shellcheck disable=SC2086
  terraform destroy \
    -var-file="../lab.tfvars" \
    -var-file="${PROVIDER}.tfvars" \
    -input=false \
    -auto-approve \
    $TF_EXTRA_ARGS
  rm -f "$REPO_ROOT/ansible-inventory.yml"
  echo "==> Done. All $PROVIDER lab resources destroyed."
  exit 0
fi

echo "==> [1/2] Provisioning infrastructure ($PROVIDER)..."
cd "$TF_DIR"
terraform init -input=false
# shellcheck disable=SC2086
terraform apply \
  -var-file="../lab.tfvars" \
  -var-file="${PROVIDER}.tfvars" \
  -input=false \
  -auto-approve \
  $TF_EXTRA_ARGS

echo "==> [2/2] Bootstrapping VMs..."
cd "$REPO_ROOT"
# shellcheck disable=SC2086
ansible-playbook \
  --become \
  -i ansible-inventory.yml \
  $ANSIBLE_VERBOSITY \
  bootstrap/site.yml
