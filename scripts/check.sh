#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
read_config
need_cmd jq
need_cmd terraform
need_cmd curl
need_cmd dig
need_hub
need_var BASE_DOMAIN
need_var LATITUDE_PROJECT
need_var LATITUDE_SITE
need_var CLUSTER_IMAGE_SET
need_file "$(local_path "$PULL_SECRET_FILE")"
need_file "$(local_path "$SSH_PUBLIC_KEY_FILE")"
jq -e 'type=="object" and has("auths")' "$(local_path "$PULL_SECRET_FILE")" >/dev/null || die "Pull secret is not valid auths JSON"
for crd in infraenvs.agent-install.openshift.io agents.agent-install.openshift.io agentclusterinstalls.extensions.hive.openshift.io clusterdeployments.hive.openshift.io; do
  hub get crd "$crd" >/dev/null || die "Missing hub CRD: $crd (enable RHACM Central Infrastructure Management)"
done
hub get clusterimageset "$CLUSTER_IMAGE_SET" >/dev/null || die "Missing ClusterImageSet $CLUSTER_IMAGE_SET"
info "Hub: $(hub whoami --show-server)"
info "OpenShift image: $(hub get clusterimageset "$CLUSTER_IMAGE_SET" -ojsonpath='{.spec.releaseImage}')"
info "Requested Latitude plan: $LATITUDE_PLAN at site $LATITUDE_SITE (confirm availability + hourly price in Latitude)"
info "Latitude project: $LATITUDE_PROJECT"
info "Cluster FQDN: $CLUSTER_NAME.$BASE_DOMAIN"
if [[ "$LATITUDE_PLAN" == "m4-metal-small" ]]; then
  info "WARNING: m4.small has six physical cores; SMT must provide >=8 logical vCPUs or Assisted Installer will reject it."
fi
info "Checks passed. No servers have been ordered and no Cloudflare records changed."
