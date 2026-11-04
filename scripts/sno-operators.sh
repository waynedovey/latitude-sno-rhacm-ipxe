#!/usr/bin/env bash
source "$(dirname "$0")/sno-lib.sh"
[[ "$(printenv CONFIRM_SNO_OPERATORS || true)" == YES ]] || die "Run CONFIRM_SNO_OPERATORS=YES make sno-operators after selecting the SNO kubeconfig"
verify_sno_context

# Installing the operators does not claim or wipe any local disk.
info "Installing LVM Storage Operator (openshift-storage) and OpenShift Virtualization (openshift-cnv)."
sno apply -f "$ROOT/manifests/sno/lvms-operator.yaml"
sno apply -f "$ROOT/manifests/sno/virtualization-operator.yaml"

wait_csv() {
  local namespace name i phase
  namespace="$1"
  name="$2"
  for ((i=1; i<=90; i++)); do
    phase="$(sno get csv -n "$namespace" -o json | jq -r --arg op "$name" '[.items[] | select(.metadata.name | contains($op)) | .status.phase] | first // ""')" || true
    [[ "$phase" == Succeeded ]] && return 0
    sleep 10
  done
  die "Operator CSV in $namespace not Succeeded after 15 minutes; inspect: oc --kubeconfig=$SNO_KUBECONFIG get csv,subscriptions,installplans -n $namespace"
}
wait_csv openshift-storage lvms
wait_csv openshift-cnv kubevirt-hyperconverged

info "Creating HyperConverged instance (OpenShift Virtualization workloads)."
sno apply -f "$ROOT/manifests/sno/hyperconverged.yaml"
info "Virtualization initialization may take 10-20 minutes."
sno wait -n openshift-cnv hyperconverged/kubevirt-hyperconverged --for=condition=Available --timeout=30m
info "Virtualization operator is available. Storage is NOT yet configured. Verify spare disk and run make sno-lvms-disk."
