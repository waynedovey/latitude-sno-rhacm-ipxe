#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
read_config
need_cmd terraform
need_var LATITUDE_AUTH_TOKEN
need_var LATITUDE_PROJECT
need_var LATITUDE_SITE
[[ "${CONFIRM_DESTROY:-}" == YES ]] || die "This terminates the billable Latitude server and loses all SNO disk data. Run CONFIRM_DESTROY=YES make destroy"
[[ -f "$ROOT/terraform/terraform.tfstate" ]] || die "No Terraform state. Do not assume billing has stopped; check the Latitude dashboard and destroy the server there if needed."
export TF_VAR_latitude_auth_token="$LATITUDE_AUTH_TOKEN"
export TF_VAR_project="$LATITUDE_PROJECT"
export TF_VAR_site="$LATITUDE_SITE"
export TF_VAR_plan="$LATITUDE_PLAN"
export TF_VAR_hostname="$LATITUDE_HOSTNAME"
# Terraform still requires a value for its iPXE input when destroying.
export TF_VAR_ipxe_script="https://example.invalid/unused-on-destroy"
terraform -chdir="$ROOT/terraform" destroy -input=false -auto-approve
info "Terraform destroy finished. Confirm the server is absent in Latitude billing/dashboard."
info "RHACM ClusterDeployment, AgentClusterInstall, InfraEnv and namespace are intentionally NOT auto-deleted."
