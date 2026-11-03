#!/usr/bin/env bash
# Read-only AWS NLB preflight, including a complete Assisted Installer rootfs download.
source "$(dirname "$0")/lib.sh"
read_config
need_cmd jq
need_cmd aws
need_cmd curl
need_hub

namespace=openshift-ingress
service="$(hub -n "$namespace" get svc "$IMAGE_NLB_SERVICE" -o json)"
jq -e '
 .spec.type=="LoadBalancer" and
 .spec.externalTrafficPolicy=="Local" and
 .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-type"]=="nlb" and
 ([.spec.ports[]|select(.name=="http" and .port==80)]|length)==1 and
 ([.spec.ports[]|select(.name=="https" and .port==443)]|length)==1
' <<< "$service" >/dev/null || die "$IMAGE_NLB_SERVICE must be a Local-traffic NLB Service with HTTP 80 and HTTPS 443"

nlb_host="$(jq -r '.status.loadBalancer.ingress[0].hostname // empty' <<< "$service")"
[[ -n "$nlb_host" ]] || die "NLB hostname has not been provisioned yet"
lbs="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --output json)"
nlb="$(jq -c --arg host "$nlb_host" '.LoadBalancers[] | select(.DNSName==$host)' <<< "$lbs")"
[[ -n "$nlb" ]] || die "Could not locate $nlb_host in AWS region $AWS_REGION"
jq -e '.Type=="network" and .Scheme=="internet-facing" and .State.Code=="active"' <<< "$nlb" >/dev/null || die "NLB must be active, public, and type network"
nlb_arn="$(jq -r '.LoadBalancerArn' <<< "$nlb")"

listeners="$(aws elbv2 describe-listeners --region "$AWS_REGION" --load-balancer-arn "$nlb_arn" --output json)"
groups="$(aws elbv2 describe-target-groups --region "$AWS_REGION" --load-balancer-arn "$nlb_arn" --output json)"
for listener_port in 80 443; do
  jq -e --argjson port "$listener_port" '
    [.Listeners[]|select(.Port==$port and .Protocol=="TCP")]|length==1
  ' <<< "$listeners" >/dev/null || die "Missing TCP listener on NLB port $listener_port"
  node_port="$(jq -r --argjson port "$listener_port" '.spec.ports[]|select(.port==$port)|.nodePort' <<< "$service")"
  target_group="$(jq -r --argjson port "$node_port" '
    [.TargetGroups[]|select(.Port==$port and .HealthCheckProtocol=="TCP" and .HealthCheckPort=="traffic-port")][0].TargetGroupArn // empty
  ' <<< "$groups")"
  [[ -n "$target_group" ]] || die "Missing target group with TCP health check for nodePort $node_port"
  health="$(aws elbv2 describe-target-health --region "$AWS_REGION" --target-group-arn "$target_group" --output json)"
  jq -e '[.TargetHealthDescriptions[]|select(.TargetHealth.State=="healthy")]|length>0' <<< "$health" >/dev/null ||
    die "No healthy NLB targets for TCP $listener_port -> $node_port"
  info "TCP $listener_port -> nodePort $node_port: AWS target healthy"
done

rootfs_url="$(hub -n "$CLUSTER_NAME" get infraenv "$CLUSTER_NAME" -o jsonpath='{.status.bootArtifacts.rootfs}')"
[[ "$rootfs_url" == http://* || "$rootfs_url" == https://* ]] || die "InfraEnv has no rootfs boot artifact; run make prepare-hub"
image_host="$(sed -E 's#^https?://([^/:]+).*#\1#' <<< "$rootfs_url")"
[[ "$image_host" != "$rootfs_url" && -n "$image_host" ]] || die "Invalid rootfs URL host"
if [[ "$rootfs_url" == https://* ]]; then port=443; else port=80; fi

tls_options=()
if [[ "${IMAGE_TLS_INSECURE:-NO}" == YES ]]; then
  tls_options+=(--insecure)
  info "WARNING: TLS certificate verification disabled for this diagnostic only"
fi
info "Downloading the entire InfraEnv rootfs through the NLB (typically >1 GiB); artifact URL is hidden."
result="$(curl --noproxy '*' --silent --show-error --http1.1 \
  --connect-to "$image_host:$port:$nlb_host:$port" \
  --fail --location --connect-timeout 15 --max-time 300 \
  --output /dev/null --write-out '%{http_code} %{size_download} %{remote_ip}' \
  "${tls_options[@]}" "$rootfs_url")" || die "Rootfs download failed through the NLB"
read -r code bytes remote_ip <<< "$result"
[[ "$code" == 200 ]] || die "Unexpected HTTP status $code"
[[ "$bytes" =~ ^[0-9]+$ ]] || die "Unexpected download size $bytes"
(( bytes >= 100000000 )) || die "Rootfs transfer too short ($bytes bytes); possible truncation"
info "Rootfs OK: HTTP $code, $bytes bytes, remote IP $remote_ip"
