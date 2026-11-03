#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
read_config
need_hub
info "=== InfraEnv and discovered agents ==="
hub -n "$CLUSTER_NAME" get infraenv,agents -o wide || true
info "=== Installation status ==="
hub -n "$CLUSTER_NAME" get clusterdeployment,agentclusterinstall || true
info "=== Managed cluster ==="
hub get managedcluster "$CLUSTER_NAME" || true
info "=== Latitude server (if local Terraform state exists) ==="
if [[ -f "$ROOT/terraform/terraform.tfstate" ]]; then
  terraform -chdir="$ROOT/terraform" state list
else
  info "No local Terraform state found."
fi
