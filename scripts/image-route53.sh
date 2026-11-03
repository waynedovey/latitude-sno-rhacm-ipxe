#!/usr/bin/env bash
# Route only the public RHACM Assisted Installer image hostname to the dedicated NLB.
source "$(dirname "$0")/lib.sh"
read_config
need_cmd jq
need_cmd aws
need_cmd sed
need_hub
need_var HUB_PUBLIC_ROUTE53_ZONE_ID
[[ "${CONFIRM_IMAGE_DNS:-}" == YES ]] || die "This changes public hub DNS. Run CONFIRM_IMAGE_DNS=YES make image-route53 after reviewing the target"

zone="$(aws route53 get-hosted-zone --id "$HUB_PUBLIC_ROUTE53_ZONE_ID" --output json)"
jq -e '.HostedZone.Config.PrivateZone==false' <<< "$zone" >/dev/null || die "HUB_PUBLIC_ROUTE53_ZONE_ID must be a public zone"
zone_name="$(jq -r '.HostedZone.Name' <<< "$zone" | sed 's/\.$//')"
rootfs_url="$(hub -n "$CLUSTER_NAME" get infraenv "$CLUSTER_NAME" -o jsonpath='{.status.bootArtifacts.rootfs}')"
[[ "$rootfs_url" == http://* || "$rootfs_url" == https://* ]] || die "InfraEnv has no rootfs boot artifact"
image_host="$(sed -E 's#^https?://([^/:]+).*#\1#' <<< "$rootfs_url")"
[[ "$image_host" != "$rootfs_url" ]] || die "Invalid image hostname"
[[ "$image_host" == "$zone_name" || "$image_host" == *".$zone_name" ]] ||
  die "Image host $image_host is outside the public Route53 zone $zone_name"

service="$(hub -n openshift-ingress get svc "$IMAGE_NLB_SERVICE" -o json)"
[[ "$(jq -r '.spec.type' <<< "$service")" == LoadBalancer ]] || die "NLB Service must be LoadBalancer"
nlb_host="$(jq -r '.status.loadBalancer.ingress[0].hostname // empty' <<< "$service")"
[[ -n "$nlb_host" ]] || die "NLB hostname is not ready"
lbs="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --output json)"
nlb="$(jq -c --arg host "$nlb_host" '.LoadBalancers[]|select(.DNSName==$host)' <<< "$lbs")"
[[ -n "$nlb" ]] || die "NLB does not exist in AWS region $AWS_REGION"
jq -e '.Type=="network" and .Scheme=="internet-facing" and .State.Code=="active"' <<< "$nlb" >/dev/null ||
  die "Expected an active public Network Load Balancer"
nlb_zone="$(jq -r '.CanonicalHostedZoneId' <<< "$nlb")"

records="$(aws route53 list-resource-record-sets --hosted-zone-id "$HUB_PUBLIC_ROUTE53_ZONE_ID" --output json)"
current="$(jq -c --arg host "$image_host." '
  [.ResourceRecordSets[]|select(.Name==$host and (.Type=="A" or .Type=="CNAME"))]
' <<< "$records")"
count="$(jq 'length' <<< "$current")"
(( count <= 1 )) || die "Multiple A/CNAME records found for $image_host; resolve them manually"
action=CREATE
if (( count == 1 )); then
  same="$(jq -r --arg dns "$nlb_host." --arg zone "$nlb_zone" '
    .[0] | (.Type=="A" and .AliasTarget.DNSName==$dns and .AliasTarget.HostedZoneId==$zone)
  ' <<< "$current")"
  if [[ "$same" == true ]]; then
    info "Route53 already aliases $image_host to $nlb_host; no DNS change required."
    exit 0
  fi
  [[ "${ALLOW_IMAGE_DNS_REPLACE:-NO}" == YES ]] ||
    die "Existing $image_host record points elsewhere; refusing to replace it without ALLOW_IMAGE_DNS_REPLACE=YES"
  [[ "$(jq -r '.[0].Type' <<< "$current")" == A ]] ||
    die "Existing CNAME requires a deliberate manual migration to A Alias"
  action=UPSERT
fi

info "Preflight: $image_host -> $nlb_host via public Route53 zone $zone_name"
bash "$ROOT/scripts/image-check.sh" || die "NLB validation failed; Route53 will not be modified"

batch="$(jq -n \
  --arg action "$action" \
  --arg name "$image_host." \
  --arg dns "$nlb_host." \
  --arg zone "$nlb_zone" '{
  Comment:"Route only RHACM Assisted Installer image traffic via a dedicated NLB",
  Changes:[{
    Action:$action,
    ResourceRecordSet:{
      Name:$name,
      Type:"A",
      AliasTarget:{HostedZoneId:$zone,DNSName:$dns,EvaluateTargetHealth:false}
    }
  }]
}')"
change="$(aws route53 change-resource-record-sets --hosted-zone-id "$HUB_PUBLIC_ROUTE53_ZONE_ID" --change-batch "$batch" --output json)"
change_id="$(jq -r '.ChangeInfo.Id' <<< "$change")"
info "Waiting for Route53 change $change_id to become INSYNC..."
aws route53 wait resource-record-sets-changed --id "$change_id"
info "Route53 alias is INSYNC. The wildcard apps record and operator-managed router have not been modified."
info "Check propagation with: dig @1.1.1.1 +short $image_host"
