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
  # Save environment-provided secrets before sourcing non-secret config.
  local saved_token="${LATITUDE_AUTH_TOKEN:-}"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  [[ -z "$saved_token" ]] || LATITUDE_AUTH_TOKEN="$saved_token"
  : "${CLUSTER_NAME:=latitude-sno}"
  : "${LATITUDE_PLAN:=m4.metal.small}"
  : "${LATITUDE_HOSTNAME:=latitude-sno}"
  : "${PULL_SECRET_FILE:=private/pull-secret.json}"
  : "${SSH_PUBLIC_KEY_FILE:=private/id_ed25519.pub}"
  [[ "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "CLUSTER_NAME must be a Kubernetes-compatible DNS label"
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
