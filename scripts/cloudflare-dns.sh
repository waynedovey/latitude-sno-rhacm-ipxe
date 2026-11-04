#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
read_config
need_cmd curl
need_cmd jq
need_var BASE_DOMAIN
resolve_latitude_network
need_var CF_API_TOKEN
[[ "${CONFIRM_DNS:-}" == YES ]] ||
  die "Cloudflare DNS changes require confirmation. Run CONFIRM_DNS=YES make dns"
ipv4_int "$NODE_IP" >/dev/null || die "NODE_IP must be a valid IPv4 address"

CF_API_URL="https://api.cloudflare.com/client/v4"
cf_call() {
  local method="$1" path="$2" body="${3:-}" response
  if [[ -n "$body" ]]; then
    response="$(curl --fail --silent --show-error --retry 2 --connect-timeout 15 \
      --request "$method" "$CF_API_URL$path" \
      --header "Authorization: Bearer $CF_API_TOKEN" \
      --header "Content-Type: application/json" \
      --data "$body")" || die "Cloudflare $method $path request failed"
  else
    response="$(curl --fail --silent --show-error --retry 2 --connect-timeout 15 \
      --request "$method" "$CF_API_URL$path" \
      --header "Authorization: Bearer $CF_API_TOKEN")" ||
      die "Cloudflare $method $path request failed"
  fi
  if ! jq -e '.success == true' <<< "$response" >/dev/null; then
    die "Cloudflare rejected $method $path: $(jq -cr '.errors // []' <<< "$response")"
  fi
  printf '%s\n' "$response"
}

if [[ -n "$CF_ZONE_ID" ]]; then
  [[ "$CF_ZONE_ID" =~ ^[a-fA-F0-9]{32}$ ]] || die "CF_ZONE_ID must be the 32-character Cloudflare zone ID"
  zone="$(cf_call GET "/zones/$CF_ZONE_ID")"
  [[ "$(jq -r '.result.name // ""' <<< "$zone")" == "$BASE_DOMAIN" ]] ||
    die "CF_ZONE_ID is not for the configured BASE_DOMAIN=$BASE_DOMAIN"
  zone_id="$CF_ZONE_ID"
else
  zones="$(cf_call GET "/zones?name=$BASE_DOMAIN&per_page=50")"
  matching="$(jq --arg name "$BASE_DOMAIN" '[.result[] | select(.name==$name)] | length' <<< "$zones")"
  (( matching == 1 )) ||
    die "Expected one Cloudflare zone named $BASE_DOMAIN; found $matching. Set CF_ZONE_ID if needed."
  zone_id="$(jq -r --arg name "$BASE_DOMAIN" '.result[] | select(.name==$name) | .id' <<< "$zones")"
fi

info "Cloudflare zone: $BASE_DOMAIN ($zone_id)"
info "DNS-only A records -> $NODE_IP. Cloudflare proxy will be OFF."
for label in "api" "api-int" "*.apps"; do
  fqdn="$label.$CLUSTER_NAME.$BASE_DOMAIN"
  # Percent-encode the wildcard in Cloudflare's DNS name query.
  qname="${fqdn/\*/%2A}"
  records="$(cf_call GET "/zones/$zone_id/dns_records?name=$qname&per_page=100")"
  record_count="$(jq --arg name "$fqdn" '[.result[] | select(.name==$name)] | length' <<< "$records")"
  (( record_count <= 1 )) ||
    die "Found $record_count records for $fqdn; fix duplicate entries in Cloudflare before retrying"
  body="$(jq -nc --arg fqdn "$fqdn" --arg ip "$NODE_IP" \
    '{type:"A", name:$fqdn, content:$ip, ttl:120, proxied:false, comment:"Managed by latitude-sno-rhacm-ipxe"}')"
  if (( record_count == 0 )); then
    cf_call POST "/zones/$zone_id/dns_records" "$body" >/dev/null
    info "Created $fqdn -> $NODE_IP (DNS only)"
    continue
  fi
  record="$(jq -c --arg name "$fqdn" '.result[] | select(.name==$name)' <<< "$records")"
  record_id="$(jq -r '.id' <<< "$record")"
  record_type="$(jq -r '.type' <<< "$record")"
  old_ip="$(jq -r '.content' <<< "$record")"
  old_proxied="$(jq -r '.proxied' <<< "$record")"
  [[ "$record_type" == A ]] ||
    die "Existing $fqdn is type $record_type, not A. Resolve conflict manually."
  if [[ "$old_ip" == "$NODE_IP" && "$old_proxied" == false ]]; then
    info "Unchanged $fqdn -> $NODE_IP"
    continue
  fi
  [[ "${ALLOW_DNS_REPLACE:-}" == YES ]] ||
    die "Existing $fqdn -> $old_ip (proxied=$old_proxied). To replace an existing record, run ALLOW_DNS_REPLACE=YES CONFIRM_DNS=YES make dns"
  cf_call PATCH "/zones/$zone_id/dns_records/$record_id" "$body" >/dev/null
  info "Updated $fqdn -> $NODE_IP (DNS only)"
done
info "Done. Check public DNS propagation with dig; make install validates all three names."
