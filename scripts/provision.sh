#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
read_config
need_cmd terraform
need_hub
need_var LATITUDE_AUTH_TOKEN
need_var LATITUDE_PROJECT
need_var LATITUDE_SITE
[[ "${CONFIRM_COST:-}" == YES ]] || die "This orders billable hourly hardware. Review Latitude price/stock, then run CONFIRM_COST=YES make provision"
url="$(get_ipxe_url)"
[[ "$url" == https://* || "$url" == http://* ]] || die "No iPXE URL. Run make prepare-hub first."
mkdir -p "$ROOT/private"
chmod 700 "$ROOT/private"
export TF_VAR_latitude_auth_token="$LATITUDE_AUTH_TOKEN"
export TF_VAR_project="$LATITUDE_PROJECT"
export TF_VAR_site="$LATITUDE_SITE"
export TF_VAR_plan="$LATITUDE_PLAN"
export TF_VAR_hostname="$LATITUDE_HOSTNAME"
export TF_VAR_ipxe_script="$url"
info "Provisioning $LATITUDE_PLAN / $LATITUDE_SITE with hourly billing. No secrets printed."
terraform -chdir="$ROOT/terraform" init -input=false
terraform -chdir="$ROOT/terraform" plan -input=false -out="$ROOT/private/provision.tfplan"
terraform -chdir="$ROOT/terraform" apply -input=false "$ROOT/private/provision.tfplan"
info "Provisioned. Use the Latitude dashboard to identify the public IPv4 and network CIDR; then run make discover."
