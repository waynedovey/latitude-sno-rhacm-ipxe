#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
read_config
need_cmd jq
need_hub
data="$(hub -n "$CLUSTER_NAME" get agents -l "latitude-sno=$CLUSTER_NAME" -o json)"
count="$(jq '.items|length' <<< "$data")"
(( count > 0 )) || die "No Latitude Agent discovered yet. Check iPXE console, DHCP, RHACM URL reachability and InfraEnv."
info "Discovered $count Agent(s). Select exactly one Agent before installing."
jq -r '
  .items[] |
  "Agent: \(.metadata.name) | approved=\(.spec.approved) | role=\(.spec.role // "auto-assign") | stage=\(.status.debugInfo.state // .status.progress.currentStage // "unknown")",
  (
    .status.inventory | if type=="string" then fromjson else . end |
    "  CPUs: \(.cpu.count // .cpu.cores // "unknown")",
    "  RAM bytes: \(.memory.physicalBytes // "unknown")",
    "  Disks (copy the desired ID into INSTALL_DISK_ID):",
    (.disks[]? | "    id=\(.id) path=\(.path // .name // "unknown") bytes=\(.sizeBytes // "unknown") eligible=\(.installationEligibility.eligible // "unknown")"),
    "  Interfaces:",
    (.interfaces[]? | "    \(.name // "unknown") MAC=\(.macAddress // "unknown") IPv4=\(.ipv4Addresses // [] | join(","))")
  )
' <<< "$data"
info "Do not assume Latitude's network from the plan alone. Get the assigned public IPv4 and subnet from the Latitude dashboard."
