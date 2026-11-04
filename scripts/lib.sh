#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT/config/lab.env}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
need_var() { local key="$1"; [[ -n "${!key:-}" ]] || die "Set $key in $CONFIG_FILE or your shell"; }
need_file() { [[ -s "$1" ]] || die "Missing/empty file: $1"; }

read_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Copy config/lab.env.example to config/lab.env and edit it"
  # Allow environment-provided tokens to take precedence over local config.
  local saved_latitude_token="${LATITUDE_AUTH_TOKEN:-}"
  local saved_cf_token="${CF_API_TOKEN:-}"
  local saved_node_ip="${NODE_IP:-}"
  local saved_machine_cidr="${MACHINE_NETWORK_CIDR:-}"
  local saved_install_disk="${INSTALL_DISK_ID:-}"
  local saved_agent_id="${AGENT_ID:-}"
  local saved_sno_kubeconfig="${SNO_KUBECONFIG:-}"
  local saved_lvms_disk="${LVMS_DISK_BY_ID:-}"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  [[ -z "$saved_latitude_token" ]] || LATITUDE_AUTH_TOKEN="$saved_latitude_token"
  [[ -z "$saved_cf_token" ]] || CF_API_TOKEN="$saved_cf_token"
  [[ -z "$saved_node_ip" ]] || NODE_IP="$saved_node_ip"
  [[ -z "$saved_machine_cidr" ]] || MACHINE_NETWORK_CIDR="$saved_machine_cidr"
  [[ -z "$saved_install_disk" ]] || INSTALL_DISK_ID="$saved_install_disk"
  [[ -z "$saved_agent_id" ]] || AGENT_ID="$saved_agent_id"
  [[ -z "$saved_sno_kubeconfig" ]] || SNO_KUBECONFIG="$saved_sno_kubeconfig"
  [[ -z "$saved_lvms_disk" ]] || LVMS_DISK_BY_ID="$saved_lvms_disk"
  : "${CLUSTER_NAME:=latitude-sno}"
  : "${BASE_DOMAIN:=digitaldovey.com}"
  : "${LATITUDE_PLAN:=f4-metal-small}"
  : "${LATITUDE_SITE:=SGP}"
  : "${LATITUDE_HOSTNAME:=latitude-sno}"
  : "${CF_ZONE_ID:=}"
  : "${AWS_REGION:=ap-southeast-2}"
  : "${IMAGE_NLB_SERVICE:=router-nlb-test}"
  : "${LATITUDE_IPXE_FORCE_HTTP:=NO}"
  : "${PULL_SECRET_FILE:=private/pull-secret.json}"
  : "${SSH_PUBLIC_KEY_FILE:=private/id_ed25519.pub}"
  [[ "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "CLUSTER_NAME must be a Kubernetes-compatible DNS label"
  [[ "$BASE_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "Invalid BASE_DOMAIN"
  # Accept the human-readable choices as well as Latitude API identifiers.
  case "$LATITUDE_SITE" in singapore|Singapore|sgp) LATITUDE_SITE=SGP;; esac
  case "$LATITUDE_PLAN" in f4.metal.small) LATITUDE_PLAN=f4-metal-small;; esac
  case "$LATITUDE_PLAN" in m4.metal.small) LATITUDE_PLAN=m4-metal-small;; esac
}

# Latitude's Terraform provider needs a project ID or slug, not its display name.
# Resolve display names using the documented read-only GET /projects API.
resolve_latitude_project() {
  need_var LATITUDE_PROJECT
  if [[ "$LATITUDE_PROJECT" =~ ^proj_[a-zA-Z0-9]+$ || "$LATITUDE_PROJECT" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    printf '%s\n' "$LATITUDE_PROJECT"
    return
  fi
  need_cmd curl
  need_cmd jq
  need_var LATITUDE_AUTH_TOKEN
  local response found count
  response="$(curl --fail --silent --show-error --retry 2 --connect-timeout 15 --get \
    --header "Authorization: $LATITUDE_AUTH_TOKEN" \
    --data-urlencode "filter[name]=$LATITUDE_PROJECT" \
    "https://api.latitude.sh/projects")" || die "Unable to look up Latitude project '$LATITUDE_PROJECT'"
  jq -e '.data | type=="array"' <<< "$response" >/dev/null || die "Latitude project lookup returned unexpected JSON"
  count="$(jq --arg name "$LATITUDE_PROJECT" '[.data[] | select(.attributes.name==$name)] | length' <<< "$response")"
  (( count == 1 )) || die "Expected one Latitude project named '$LATITUDE_PROJECT'; found $count. Set LATITUDE_PROJECT to its proj_ ID or slug instead."
  found="$(jq -r --arg name "$LATITUDE_PROJECT" '.data[] | select(.attributes.name==$name) | .id' <<< "$response")"
  [[ "$found" == proj_* ]] || die "Latitude project lookup returned an invalid ID"
  printf '%s\n' "$found"
}

local_path() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$ROOT" "$1";; esac; }
hub() {
  if [[ -n "${RHACM_KUBECONFIG:-}" ]]; then
    KUBECONFIG="$RHACM_KUBECONFIG" oc "$@"
  else
    oc "$@"
  fi
}
need_hub() {
  need_cmd oc
  hub whoami >/dev/null || die "Cannot reach existing RHACM hub (set RHACM_KUBECONFIG)"
}
get_ipxe_url() {
  hub -n "$CLUSTER_NAME" get infraenv "$CLUSTER_NAME" -o jsonpath='{.status.bootArtifacts.ipxeScript}'
}
ipv4_int() {
  local a b c d n
  IFS=. read -r a b c d <<< "$1"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" =~ ^[0-9]+$ ]] && (( 10#$n <= 255 )) || return 1
  done
  printf '%s\n' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}
in_ipv4_cidr() {
  local cidr_ip prefix a b mask
  IFS=/ read -r cidr_ip prefix <<< "$2"
  [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix >= 0 && prefix <= 32 )) || return 1
  a="$(ipv4_int "$1")" || return 1
  b="$(ipv4_int "$cidr_ip")" || return 1
  if (( prefix == 0 )); then mask=0; else mask=$(( (0xffffffff << (32-prefix)) & 0xffffffff )); fi
  (( (a & mask) == (b & mask) ))
}


# Resolve the provisioned server's management IP and network from Latitude.
# Values may be explicitly overridden, but never inferred from the server plan.
resolve_latitude_network() {
  [[ -n "${NODE_IP:-}" && -n "${MACHINE_NETWORK_CIDR:-}" ]] && return 0
  need_cmd terraform
  need_cmd curl
  need_cmd jq
  need_var LATITUDE_AUTH_TOKEN
  [[ -f "$ROOT/terraform/terraform.tfstate" ]] ||
    die "No Terraform state. Provision the server first or explicitly set NODE_IP and MACHINE_NETWORK_CIDR."

  local server_id response count address cidr
  server_id="$(terraform -chdir="$ROOT/terraform" output -raw server_id)" ||
    die "Cannot read Latitude server ID from Terraform state"
  [[ "$server_id" == sv_* ]] || die "Unexpected Latitude server ID: $server_id"
  response="$(curl --fail --silent --show-error --retry 2 --connect-timeout 15 --get \
    --header "Authorization: $LATITUDE_AUTH_TOKEN" \
    --data-urlencode "filter[server]=$server_id" \
    --data-urlencode "filter[management]=true" \
    --data-urlencode "page[size]=100" \
    "https://api.latitude.sh/ips")" ||
    die "Unable to look up assigned management IPv4 for Latitude server $server_id"

  count="$(jq '[.data[]? | select(.attributes.management == true)
    | select(.attributes.address | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))] | length' <<< "$response")"
  (( count == 1 )) ||
    die "Expected exactly one management IPv4 for server $server_id; found $count. Set explicit overrides after verifying Latitude networking."
  address="$(jq -r '.data[] | select(.attributes.management == true)
    | select(.attributes.address | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$"))
    | .attributes.address' <<< "$response")"
  cidr="$(jq -r --arg ip "$address" '.data[] | select(.attributes.address == $ip) | .attributes.cidr // empty' <<< "$response")"

  [[ -z "${NODE_IP:-}" || "$NODE_IP" == "$address" ]] ||
    die "NODE_IP=$NODE_IP disagrees with Latitude's management IPv4 $address"
  NODE_IP="$address"

  # Normalize host/prefix to the actual network address/prefix.
  if [[ "$cidr" =~ ^[0-9]+$ ]]; then cidr="$NODE_IP/$cidr"; fi
  if [[ "$cidr" =~ ^/[0-9]+$ ]]; then cidr="$NODE_IP$cidr"; fi
  if [[ -z "${MACHINE_NETWORK_CIDR:-}" ]]; then
    [[ -n "$cidr" ]] || die "Latitude did not return a CIDR. Verify its network; do not guess /24 or /31."
    MACHINE_NETWORK_CIDR="$(canonical_ipv4_cidr "$cidr")" ||
      die "Unexpected Latitude management network CIDR: $cidr"
  fi
  in_ipv4_cidr "$NODE_IP" "$MACHINE_NETWORK_CIDR" ||
    die "Latitude management IPv4 $NODE_IP is outside $MACHINE_NETWORK_CIDR"
  info "Latitude network auto-detected: $NODE_IP on $MACHINE_NETWORK_CIDR (server $server_id)."
}

canonical_ipv4_cidr() {
  local address prefix ip mask network
  IFS=/ read -r address prefix <<< "$1"
  [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix >= 0 && prefix <= 32 )) || return 1
  ip="$(ipv4_int "$address")" || return 1
  if (( prefix == 0 )); then mask=0
  else mask=$(( (0xffffffff << (32-prefix)) & 0xffffffff ))
  fi
  network=$(( ip & mask ))
  printf '%d.%d.%d.%d/%d\n' \
    "$(( (network >> 24) & 255 ))" "$(( (network >> 16) & 255 ))" \
    "$(( (network >> 8) & 255 ))" "$(( network & 255 ))" "$prefix"
}
