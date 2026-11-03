#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
read_config
need_cmd jq
need_hub
need_file "$(local_path "$PULL_SECRET_FILE")"
need_file "$(local_path "$SSH_PUBLIC_KEY_FILE")"
ssh_key="$(<"$(local_path "$SSH_PUBLIC_KEY_FILE")")"
[[ "$ssh_key" == ssh-* || "$ssh_key" == ecdsa-* ]] || die "Invalid SSH public key"

hub create namespace "$CLUSTER_NAME" --dry-run=client -o yaml | hub apply -f -
hub -n "$CLUSTER_NAME" create secret generic pull-secret \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=".dockerconfigjson=$(local_path "$PULL_SECRET_FILE")" \
  --dry-run=client -o yaml | hub apply -f -

jq -n --arg name "$CLUSTER_NAME" --arg ssh "$ssh_key" '{
  apiVersion:"agent-install.openshift.io/v1beta1", kind:"InfraEnv",
  metadata:{name:$name, namespace:$name},
  spec:{
    pullSecretRef:{name:"pull-secret"},
    sshAuthorizedKey:$ssh,
    agentLabels:{"latitude-sno":$name},
    ipxeScriptType:"BootOrderControl"
  }
}' | hub apply -f -

info "Waiting for RHACM iPXE artifact (URL is intentionally hidden)..."
for ((i=1;i<=30;i++)); do
  url="$(get_ipxe_url)"
  if [[ "$url" == https://* || "$url" == http://* ]]; then
    info "InfraEnv is ready. Run CONFIRM_COST=YES make provision."
    exit 0
  fi
  sleep 10
done
die "InfraEnv did not publish status.bootArtifacts.ipxeScript after 5 minutes; inspect the InfraEnv and assisted-image-service pods."
