#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"

read_config
need_cmd oc
need_cmd jq
need_var SNO_KUBECONFIG
[[ -s "$SNO_KUBECONFIG" ]] || die "SNO_KUBECONFIG must point to the installed SNO cluster's kubeconfig, not the RHACM hub's"

sno() {
  oc --kubeconfig="$SNO_KUBECONFIG" "$@"
}

verify_sno_context() {
  local server expected version ready node_json
  server="$(sno whoami --show-server)" || die "SNO kubeconfig cannot connect"
  expected="https://api.$CLUSTER_NAME.$BASE_DOMAIN:6443"
  [[ "$server" == "$expected" ]] || die "Refusing to modify unexpected cluster API: $server (expected $expected)"
  version="$(sno get clusterversion version -o jsonpath='{.status.desired.version}')"
  [[ "$version" == 4.22.* ]] || die "Expected OpenShift 4.22 for these operator channels, got '$version'"
  node_json="$(sno get nodes -o json)"
  [[ "$(jq -r '.items | length' <<< "$node_json")" == 1 ]] || die "Expected exactly one SNO node; inspect cluster membership"
  SNO_NODE="$(jq -r '.items[0].metadata.name' <<< "$node_json")"
  ready="$(jq -r '.items[0].status.conditions[] | select(.type=="Ready") | .status' <<< "$node_json")"
  [[ "$ready" == True ]] || die "SNO node $SNO_NODE is not Ready"
  info "Confirmed SNO API $server, OpenShift $version, node $SNO_NODE Ready."
}
