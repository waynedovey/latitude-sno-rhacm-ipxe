#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
read_config
need_cmd terraform
need_cmd jq
need_var LATITUDE_AUTH_TOKEN
need_var LATITUDE_SITE
[[ "${CONFIRM_DESTROY:-}" == YES ]] || die "This terminates the billable Latitude server and loses all SNO disk data. Run CONFIRM_DESTROY=YES make destroy"
[[ -f "$ROOT/terraform/terraform.tfstate" ]] || die "No Terraform state. Check the Latitude dashboard and release the server there if needed."
# Read the original project from state: project renames or API outages must not block cleanup.
project_id="$(terraform -chdir="$ROOT/terraform" show -json | jq -er '.values.root_module.resources[] | select(.address=="latitudesh_server.sno") | .values.project')" ||
  die "Cannot read the Latitude project from state; check Terraform state and the Latitude dashboard."
export TF_VAR_latitude_auth_token="$LATITUDE_AUTH_TOKEN"
export TF_VAR_project="$project_id"
export TF_VAR_site="$LATITUDE_SITE"
export TF_VAR_plan="$LATITUDE_PLAN"
export TF_VAR_hostname="$LATITUDE_HOSTNAME"
# Terraform requires an iPXE value even during destroy.
export TF_VAR_ipxe_script="https://example.invalid/unused-on-destroy"
terraform -chdir="$ROOT/terraform" destroy -input=false -auto-approve
info "Terraform destroy finished. Confirm the server is absent in Latitude billing/dashboard."
info "RHACM ClusterDeployment, AgentClusterInstall, InfraEnv and namespace were intentionally NOT auto-deleted."
