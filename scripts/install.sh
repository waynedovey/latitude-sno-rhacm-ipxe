#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
read_config
need_cmd jq
need_cmd dig
need_hub
need_var CLUSTER_IMAGE_SET
need_var BASE_DOMAIN
need_var NODE_IP
need_var MACHINE_NETWORK_CIDR
need_var INSTALL_DISK_ID
[[ "${CONFIRM_INSTALL:-}" == YES ]] || die "Installation erases the selected NVMe disk. Inspect make discover, then run CONFIRM_INSTALL=YES make install"

ipv4_int "$NODE_IP" >/dev/null || die "NODE_IP is not valid IPv4"
in_ipv4_cidr "$NODE_IP" "$MACHINE_NETWORK_CIDR" || die "NODE_IP is not inside MACHINE_NETWORK_CIDR"
hub get clusterimageset "$CLUSTER_IMAGE_SET" >/dev/null || die "ClusterImageSet does not exist: $CLUSTER_IMAGE_SET"
need_file "$(local_path "$SSH_PUBLIC_KEY_FILE")"
ssh_key="$(<"$(local_path "$SSH_PUBLIC_KEY_FILE")")"
for name in "api.$CLUSTER_NAME.$BASE_DOMAIN" "api-int.$CLUSTER_NAME.$BASE_DOMAIN" "probe.apps.$CLUSTER_NAME.$BASE_DOMAIN"; do
  dig +short "$name" A | grep -Fxq "$NODE_IP" || die "DNS $name must resolve to $NODE_IP before installation"
done

agents="$(hub -n "$CLUSTER_NAME" get agents -l "latitude-sno=$CLUSTER_NAME" -o json)"
count="$(jq '.items|length' <<< "$agents")"
if [[ -n "${AGENT_ID:-}" ]]; then
  agent="$(jq -r --arg id "$AGENT_ID" '.items[] | select(.metadata.name==$id) | .metadata.name' <<< "$agents")"
  [[ "$agent" == "$AGENT_ID" ]] || die "AGENT_ID is not in this InfraEnv"
else
  (( count == 1 )) || die "Expected exactly one discovered Agent; specify AGENT_ID to select one"
  agent="$(jq -r '.items[0].metadata.name' <<< "$agents")"
fi
selected="$(jq -c --arg id "$agent" '.items[]|select(.metadata.name==$id)' <<< "$agents")"
[[ "$(jq -r '.spec.approved' <<< "$selected")" != true ]] || die "Agent already approved; refusing potentially disruptive reconfiguration"
existing="$(jq -r '.spec.clusterDeploymentName.name // ""' <<< "$selected")"
[[ -z "$existing" || "$existing" == "$CLUSTER_NAME" ]] || die "Agent belongs to another cluster: $existing"
inventory="$(jq -c '.status.inventory | if type=="string" then fromjson else . end' <<< "$selected")"
[[ "$inventory" != "null" ]] || die "Agent has no inventory yet"
cpu="$(jq -r '.cpu.count // .cpu.cores // 0' <<< "$inventory")"
ram="$(jq -r '.memory.physicalBytes // 0' <<< "$inventory")"
(( cpu >= 8 )) || die "Only $cpu CPUs reported (SNO requires at least 8 logical vCPUs); use a bigger Latitude plan"
(( ram >= 17179869184 )) || die "Less than 16 GiB RAM reported; use a bigger Latitude plan"
disk="$(jq -c --arg id "$INSTALL_DISK_ID" '.disks[]? | select(.id==$id)' <<< "$inventory")"
[[ -n "$disk" ]] || die "INSTALL_DISK_ID not found in discovered Agent inventory"
disk_bytes="$(jq -r '.sizeBytes // 0' <<< "$disk")"
(( disk_bytes >= 128849018880 )) || die "Selected disk is smaller than 120 GiB"
[[ "$(jq -r '.installationEligibility.eligible // true' <<< "$disk")" == true ]] || die "Selected disk is not eligible for installation"
info "Validated Agent $agent: $cpu CPUs, RAM $ram bytes, selected disk $INSTALL_DISK_ID ($(jq -r '.path // .name' <<< "$disk"))."
info "DNS and CIDR preflight passed. PlatformType None: no BMC, no external VIP allocation."

jq -n --arg name "$CLUSTER_NAME" --arg domain "$BASE_DOMAIN" '{
  apiVersion:"hive.openshift.io/v1", kind:"ClusterDeployment",
  metadata:{name:$name,namespace:$name},
  spec:{
    clusterName:$name,baseDomain:$domain,
    clusterInstallRef:{group:"extensions.hive.openshift.io",kind:"AgentClusterInstall",name:$name,version:"v1beta1"},
    pullSecretRef:{name:"pull-secret"},
    controlPlaneConfig:{servingCertificates:{}},
    platform:{agentBareMetal:{agentSelector:{matchLabels:{"latitude-sno":$name}}}}
  }
}' | hub apply -f -

jq -n --arg name "$CLUSTER_NAME" --arg image "$CLUSTER_IMAGE_SET" \
   --arg network "$MACHINE_NETWORK_CIDR" --arg ssh "$ssh_key" '{
  apiVersion:"extensions.hive.openshift.io/v1beta1", kind:"AgentClusterInstall",
  metadata:{name:$name,namespace:$name},
  spec:{
    platformType:"None", clusterDeploymentRef:{name:$name},
    imageSetRef:{name:$image},
    networking:{
      clusterNetwork:[{cidr:"10.128.0.0/14",hostPrefix:23}],
      machineNetwork:[{cidr:$network}],
      serviceNetwork:["172.30.0.0/16"]
    },
    provisionRequirements:{controlPlaneAgents:1,workerAgents:0},
    sshPublicKey:$ssh
  }
}' | hub apply -f -

patch="$(jq -n --arg name "$CLUSTER_NAME" --arg disk "$INSTALL_DISK_ID" '{
  spec:{
    approved:false,role:"master",
    installation_disk_id:$disk,
    clusterDeploymentName:{name:$name,namespace:$name}
  }
}')"
hub -n "$CLUSTER_NAME" patch agent "$agent" --type=merge -p "$patch" >/dev/null
info "Waiting up to 10 minutes for RHACM host validation before approval..."
for ((i=1;i<=60;i++)); do
  status="$(hub -n "$CLUSTER_NAME" get agent "$agent" -o json)"
  valid="$(jq -r '[.status.conditions[]? | select(.type=="Validated") | .status] | .[0] // "Unknown"' <<< "$status")"
  if [[ "$valid" == True ]]; then
    hub -n "$CLUSTER_NAME" patch agent "$agent" --type=merge -p '{"spec":{"approved":true}}'
    info "Agent approved. Run make status to watch SNO install."
    exit 0
  fi
  sleep 10
done
die "Validation not True after 10 minutes. Agent remains UNAPPROVED; review RHACM Agent/AgentClusterInstall conditions."
