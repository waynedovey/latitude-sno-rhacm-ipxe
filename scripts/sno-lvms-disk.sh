#!/usr/bin/env bash
source "$(dirname "$0")/sno-lib.sh"
verify_sno_context
need_var LVMS_DISK_BY_ID

# NVMe kernel names can switch between boots. A by-id path is mandatory.
[[ "$LVMS_DISK_BY_ID" == /dev/disk/by-id/nvme-* ]] || die "LVMS_DISK_BY_ID must be a whole NVMe /dev/disk/by-id/nvme-* link, never /dev/nvme0n1"
info "Read-only disk validation on $SNO_NODE for $LVMS_DISK_BY_ID."
sno debug "node/$SNO_NODE" -- chroot /host /bin/bash -c '
set -euo pipefail
requested="$1"
[[ -L "$requested" ]] || { echo "ERROR: Hardware by-id link is missing: $requested" >&2; exit 1; }
disk="$(readlink -f "$requested")"
[[ "$disk" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]] || { echo "ERROR: Not a whole NVMe disk: $disk" >&2; exit 1; }
[[ "$(lsblk -dnro TYPE "$disk")" == disk ]] || { echo "ERROR: Selected path is not a disk" >&2; exit 1; }
num="$(lsblk -nrpo TYPE "$disk" | wc -l | tr -d "[:space:]")"
[[ "$num" == 1 ]] || { echo "ERROR: $disk has partitions or child devices" >&2; exit 1; }
[[ -z "$(lsblk -dnro FSTYPE "$disk")" ]] || { echo "ERROR: $disk has a filesystem signature" >&2; exit 1; }
[[ -z "$(wipefs -n "$disk")" ]] || { echo "ERROR: $disk has partition or filesystem signatures" >&2; exit 1; }
[[ -z "$(lsblk -dnro MOUNTPOINTS "$disk")" ]] || { echo "ERROR: $disk is mounted" >&2; exit 1; }
echo "Spare candidate: $requested -> $disk"
lsblk -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$disk"
echo "No child partitions, mounts, or signatures found. This does NOT prove unused data cannot exist."
' _ "$LVMS_DISK_BY_ID" || die "Disk preflight failed. No LVMCluster was created."

if [[ "$(printenv SNO_DISK_ACTION || true)" == check ]]; then
  info "Disk check complete. No changes made to storage."
  exit 0
fi

[[ "$(printenv CONFIRM_LVMS_DISK || true)" == YES ]] || die "Disk will be allocated to LVMS. If you accept permanent data loss on this disk, run CONFIRM_LVMS_DISK=YES make sno-lvms-disk"
sno get crd lvmclusters.lvm.topolvm.io >/dev/null || die "LVM Storage CRD not present; run make sno-operators first"
existing="$(sno get lvmclusters.lvm.topolvm.io -A -o json | jq -r '.items | length')"
[[ "$existing" == 0 ]] || die "An LVMCluster already exists; refusing to reconfigure it"

# An explicit by-id path avoids automatically discovering other disks.
# forceWipe=false refuses devices with signatures; NEVER set it to true here.
info "Creating LVMS vg1 using ONLY $LVMS_DISK_BY_ID."
sno apply -f - <<YAML
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
      - name: vg1
        default: true
        fstype: xfs
        deviceSelector:
          paths:
            - $LVMS_DISK_BY_ID
          forceWipeDevicesAndDestroyAllData: false
        thinPoolConfig:
          name: thin-pool-1
          sizePercent: 90
          overprovisionRatio: 10
YAML

for ((i=1; i<=120; i++)); do
  state="$(sno get lvmcluster lvmcluster -n openshift-storage -o jsonpath='{.status.state}')"
  [[ "$state" == Ready ]] && break
  [[ "$state" == Failed ]] && die "LVMCluster failed; inspect: oc --kubeconfig=$SNO_KUBECONFIG describe lvmcluster lvmcluster -n openshift-storage"
  sleep 10
done
[[ "$state" == Ready ]] || die "LVMCluster did not become Ready within 20 minutes"
sno get sc lvms-vg1
info "LVM Storage Ready. lvms-vg1 can back VM PVCs on this one SNO node."
