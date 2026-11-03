#!/usr/bin/env bash
# Create the dedicated AWS NLB for the RHACM Assisted Installer image service.
source "$(dirname "$0")/lib.sh"
read_config
need_cmd jq
need_hub
[[ "$IMAGE_NLB_SERVICE" != "router-default" ]] || die "Never replace the operator-managed router-default Service"
[[ "${CONFIRM_IMAGE_NLB:-}" == YES ]] || die "Creates an hourly-billed AWS NLB. Run CONFIRM_IMAGE_NLB=YES make image-nlb after checking AWS pricing"

namespace=openshift-ingress
router="$(hub -n "$namespace" get svc router-default -o json)"
jq -e '.spec.selector | type=="object" and length>0' <<< "$router" >/dev/null || die "router-default has no usable selector"
jq -e '[.spec.ports[] | select(.name=="http" and .port==80)] | length==1' <<< "$router" >/dev/null || die "router-default has no named HTTP port"
jq -e '[.spec.ports[] | select(.name=="https" and .port==443)] | length==1' <<< "$router" >/dev/null || die "router-default has no named HTTPS port"

existing="$(hub -n "$namespace" get svc "$IMAGE_NLB_SERVICE" -o json 2>/dev/null || true)"
if [[ -n "$existing" ]]; then
  jq -e --argjson selector "$(jq -c '.spec.selector' <<< "$router")" '
    .spec.type=="LoadBalancer" and
    .spec.selector==$selector and
    .metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-type"]=="nlb"
  ' <<< "$existing" >/dev/null || die "Existing $IMAGE_NLB_SERVICE is not our NLB Service; refusing to modify it"
fi

jq -n \
  --arg name "$IMAGE_NLB_SERVICE" \
  --argjson selector "$(jq -c '.spec.selector' <<< "$router")" '{
  apiVersion:"v1",kind:"Service",
  metadata:{
    name:$name,namespace:"openshift-ingress",
    annotations:{
      "service.beta.kubernetes.io/aws-load-balancer-type":"nlb",
      "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes":"proxy_protocol_v2.enabled=true",
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol":"tcp",
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port":"traffic-port"
    }
  },
  spec:{
    type:"LoadBalancer",
    externalTrafficPolicy:"Local",
    selector:$selector,
    ports:[
      {name:"http",port:80,targetPort:"http",protocol:"TCP"},
      {name:"https",port:443,targetPort:"https",protocol:"TCP"}
    ]
  }
}' | hub -n "$namespace" apply -f -

info "Dedicated NLB Service applied; default router and wildcard DNS unchanged."
hub -n "$namespace" get svc "$IMAGE_NLB_SERVICE"
info "Wait for an EXTERNAL-IP hostname and healthy AWS targets; run make image-check."
