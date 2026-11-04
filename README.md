# Latitude.sh SNO — RHACM Assisted Installer + iPXE

Deploy a **single-node OpenShift (SNO)** cluster on Latitude.sh bare metal using an **existing RHACM hub**, Terraform, and Assisted Installer iPXE. An optional AWS Network Load Balancer (NLB) avoids truncated RHCOS image downloads from the hub, while Cloudflare publishes the **new SNO cluster's** DNS after the server receives its public IP.

## Lab defaults

| Setting | Value |
| --- | --- |
| Cluster | `latitude-sno` |
| Domain | `digitaldovey.com` |
| Latitude project | `Red Hat SSA Sandbox` |
| Latitude site | Singapore (`SGP`) |
| Latitude plan | `f4.metal.small` (API slug: `f4-metal-small`) |
| Billing | Hourly, explicitly configured |

The plan is **12 physical cores / 96 GB RAM**. Verify **Singapore stock, current hourly rate and iPXE compatibility** in the [Latitude dashboard](https://www.latitude.sh/dashboard/) before approving an order. This repository does **not** order hardware on its own.

## Quick start (macOS)

Requires `oc` logged into an RHACM/MCE hub with Central Infrastructure Management, Terraform ≥1.6, `jq`, `curl`, `dig`, a Red Hat pull secret, and Cloudflare DNS for the SNO domain. The optional AWS hub ingress workflow also requires `aws` CLI v2, existing AWS permissions for ELBv2/Route53, and a **public Route53 hosted zone** for the hub's image-service hostname.

```bash
git clone https://github.com/waynedovey/latitude-sno-rhacm-ipxe.git
cd latitude-sno-rhacm-ipxe
mkdir -p private
cp config/lab.env.example config/lab.env

# Set CLUSTER_IMAGE_SET in config/lab.env; check the other defaults.
oc get clusterimagesets
# Save pull secret to private/pull-secret.json.
# Save SSH public key to private/id_ed25519.pub.
export LATITUDE_AUTH_TOKEN="YOUR_LATITUDE_TOKEN"

make check
make prepare-hub

# On an AWS hub with truncated image downloads, complete the hub NLB
# and Route53 workflow below before provisioning the Latitude server.
CONFIRM_COST=YES make provision
make discover
```

The scripts resolve the Latitude project display name to its project ID using the Latitude API. If preferred, set `LATITUDE_PROJECT` to a `proj_...` ID or slug directly. No server order occurs without `CONFIRM_COST=YES`.

When the Agent appears, set the real `NODE_IP`, `MACHINE_NETWORK_CIDR`, and `INSTALL_DISK_ID` in your ignored `config/lab.env` (use the discovered **disk ID**, not a guessed device path).

### AWS hub image ingress (when using RHACM/MCE on AWS)

**This is separate from Cloudflare DNS for the SNO cluster.** On the AWS RHACM hub, the existing wildcard `*.apps.hub.<hub-domain>` can remain on the operator-managed router's Classic Load Balancer. A dedicated **public NLB** serves only the Assisted Installer's large boot artifacts, and an explicit Route53 **A Alias** for the image service takes precedence over the wildcard. Do **not** change `router-default` or repoint the wildcard.

This was needed in the November 2026 Latitude lab: the original path truncated the ~1.13 GiB `rootfs` download, while the NLB transferred all **1,218,105,344 bytes** (HTTP 200); after reboot, RHCOS started and the Agent appeared in RHACM. The lab's pre-existing NLB Service is named `router-nlb-test` — that is the default in `config/lab.env.example`. Choose another name only if you intend to create another hourly-billed NLB.

1. Set `AWS_REGION`, `HUB_PUBLIC_ROUTE53_ZONE_ID` (the **public zone containing** the hub image hostname), and `IMAGE_NLB_SERVICE` in the ignored `config/lab.env`. Use normal AWS CLI credentials. Do not confuse the public hub zone with `BASE_DOMAIN=digitaldovey.com`, which is for the new SNO cluster.
2. Provision or reconcile a **separate** NLB Service for ingress HTTP/HTTPS (with Proxy Protocol v2, TCP health checks, and `externalTrafficPolicy: Local`):

   ```bash
   CONFIRM_IMAGE_NLB=YES make image-nlb
   ```

3. Verify TCP **80 and 443** listeners and healthy nodePort targets, then download the entire rootfs *directly through the NLB*, without any DNS changes:

   ```bash
   make image-check
   ```

4. Create the explicit Route53 Alias only after the image check succeeds:

   ```bash
   CONFIRM_IMAGE_DNS=YES make image-route53
   ```

   The DNS script runs the full NLB/rootfs validation again before applying the record, waits for Route53 **INSYNC**, and is idempotent. It refuses to replace another A record unless `ALLOW_IMAGE_DNS_REPLACE=YES` is explicitly supplied; existing CNAME records require manual migration. Check propagation:

   ```bash
   dig @1.1.1.1 +short assisted-image-service-multicluster-engine.apps.hub.sandbox312.opentlc.com
   ```

These scripts derive the image hostname from `InfraEnv.status.bootArtifacts.rootfs` and the NLB DNS/alias zone ID from AWS. They do **not** hard-code the example sandbox's ELB, nodePort, or hosted-zone ID, and they never overwrite the wildcard record. An NLB incurs AWS costs; leave it in place only as long as your lab needs it. To revert DNS, remove **only** the exact image-service Alias after confirming it is still the record created for this NLB.

**HTTPS iPXE note:** If Latitude firmware cannot validate the InfraEnv's HTTPS iPXE script, `LATITUDE_IPXE_FORCE_HTTP=YES` explicitly converts the script URL to HTTP when `make provision` runs. HTTP exposes an access-bearing URL in transit: leave this setting `NO` by default, use it only in an isolated lab with accepted risk, and restore HTTPS when possible. This does not disable TLS verification on the hub or the NLB.

### Configure Cloudflare DNS

Create a [Cloudflare API token](https://dash.cloudflare.com/profile/api-tokens) restricted to the `digitaldovey.com` zone, with **Zone / Zone / Read** and **Zone / DNS / Edit** permissions. The script looks up the zone ID automatically; optionally set `CF_ZONE_ID` in `config/lab.env`.

```bash
export CF_API_TOKEN="YOUR_CLOUDFLARE_TOKEN"
CONFIRM_DNS=YES make dns
```

Only three **DNS-only (unproxied) A** records are created:

| Record | Target |
| --- | --- |
| `api.latitude-sno.digitaldovey.com` | `NODE_IP` |
| `api-int.latitude-sno.digitaldovey.com` | `NODE_IP` |
| `*.apps.latitude-sno.digitaldovey.com` | `NODE_IP` |

`make dns` is idempotent. It **refuses to overwrite** an existing record pointing elsewhere or with the Cloudflare proxy enabled unless you explicitly pass `ALLOW_DNS_REPLACE=YES` as well. It never modifies other domains or records. Ensure your domain's nameservers actually delegate to Cloudflare and allow DNS propagation before installing.

### Install and clean up

```bash
CONFIRM_INSTALL=YES make install
make status

# When finished, terminate hourly-billed hardware:
CONFIRM_DESTROY=YES make destroy
```

**Important:** Installation overwrites the selected NVMe disk. Ensure the node's public IPv4 stays stable, the node reaches RHACM and image registries, and clients can reach TCP **6443 / 80 / 443**. The install script checks public DNS resolution before approving the Agent.

## Post-install: LVM Storage + OpenShift Virtualization (4.22)

After SNO completes installation, the optional post-install workflow installs **Red Hat LVM Storage** and **OpenShift Virtualization**. It operates **only** against the installed SNO API, refusing the RHACM hub kubeconfig. Local LVMS on SNO is not HA and cannot support cross-node VM live migration.

### 1. Obtain the new SNO kubeconfig

From your Mac, while logged into the **RHACM hub**:

```bash
oc -n latitude-sno get clusterdeployment latitude-sno \
  -o jsonpath='{.status.clusterMetadata.adminKubeconfigSecretRef.name}{"\n"}'

# Use the actual referenced secret name, if different:
SECRET_NAME=latitude-sno-admin-kubeconfig
mkdir -p private
oc -n latitude-sno get secret "$SECRET_NAME" \
  -o jsonpath='{.data.kubeconfig}' | base64 -D > private/latitude-sno.kubeconfig
chmod 600 private/latitude-sno.kubeconfig

oc --kubeconfig=private/latitude-sno.kubeconfig get nodes -o wide
oc --kubeconfig=private/latitude-sno.kubeconfig get clusterversion
```

If the secret reference is missing, the Assisted Installer may still be finishing. Set `SNO_KUBECONFIG=private/latitude-sno.kubeconfig` in the ignored `config/lab.env`. Never use the hub's kubeconfig for the following steps.

### 2. Install both operators (does not claim storage)

```bash
CONFIRM_SNO_OPERATORS=YES make sno-operators
oc --kubeconfig=private/latitude-sno.kubeconfig get csv -n openshift-storage
oc --kubeconfig=private/latitude-sno.kubeconfig get csv -n openshift-cnv
oc --kubeconfig=private/latitude-sno.kubeconfig get hyperconverged -n openshift-cnv
```

The script validates the SNO API hostname, OpenShift version 4.22, and exactly one Ready node, then installs LVMS in `openshift-storage` and Virtualization in `openshift-cnv`. It creates the `HyperConverged` resource after the Virtualization CSV succeeds. **No LVMCluster is created yet.**

### 3. Identify the spare NVMe by stable hardware ID

**Do not assume `/dev/nvme0n1` is always spare.** Earlier Agent discovery selected that kernel name for OS installation; a later RHCOS boot showed four OS partitions on `/dev/nvme1n1`. The names can switch between boots.

```bash
ssh core@206.223.224.31 'sudo lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,WWN
for id in /dev/disk/by-id/nvme-eui.*; do
  printf "%s -> " "$id"
  readlink -f "$id"
done
sudo wipefs -n /dev/nvme0n1
sudo wipefs -n /dev/nvme1n1
sudo pvs'
```

Identify the **whole** 960 GB NVMe without partitions, mounts, or signatures. Confirm there is no useful data on it. Even if it appears empty, it could contain unrecognised data. Put the verified **spare disk's** by-id path into ignored `config/lab.env`:

```bash
# EXAMPLE ONLY. Replace with the actual by-id ID resolved on the installed node.
LVMS_DISK_BY_ID=/dev/disk/by-id/nvme-eui.REPLACE_WITH_VERIFIED_SPARE_ID
```

Run the read-only device check:

```bash
make sno-disk-check
```

The script runs a host-side check through `oc debug node` and rejects devices that have partitions, mounts, or filesystem signatures. If this step fails, it creates **no LVMCluster**.

### 4. Explicitly allocate the spare NVMe to LVMS

**Only after verifying the drive's physical identity and accepting that allocating it to LVMS will make existing data on the whole disk unusable:**

```bash
CONFIRM_LVMS_DISK=YES make sno-lvms-disk

oc --kubeconfig=private/latitude-sno.kubeconfig get lvmcluster lvmcluster -n openshift-storage
oc --kubeconfig=private/latitude-sno.kubeconfig get sc lvms-vg1
oc --kubeconfig=private/latitude-sno.kubeconfig get pods -n openshift-cnv
```

The generated LVMCluster explicitly chooses **only the verified by-id path**, sets `forceWipeDevicesAndDestroyAllData: false`, and configures an XFS-backed `vg1` with a 90% thin pool. The local storage class is `lvms-vg1`. Do not automatically force-wipe an unidentified or OS disk.

References: [OpenShift 4.22 LVMS](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/storage/persistent-storage-using-local-storage) and [OpenShift 4.22 Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/virtualization/installing).

## Workflow

1. `make prepare-hub`: creates a pull secret and InfraEnv in the existing RHACM hub, producing an iPXE boot URL.
2. **If the hub's large image download is truncated:** `make image-nlb`, `make image-check`, and `make image-route53` after explicit confirmation; preserves default router and wildcard.
3. `make provision`: Terraform orders the Latitude server in **SGP**, boots RHACM iPXE and uses **hourly** billing.
4. `make discover`: inspects the Agent, disks and hardware checks. Seeing `APPROVED=false` / `ROLE=auto-assign` initially is normal.
5. `make dns`: creates the three Cloudflare records for the assigned IP.
6. `make install`: validates the selected disk and host, creates the AgentClusterInstall/ClusterDeployment, and then approves the Agent; `make status` monitors it.
7. `make destroy`: releases the billed server (does not automatically delete RHACM, NLB, Route53, or Cloudflare resources).

`config/lab.env`, API tokens, pull secrets, kubeconfigs and Terraform state/plans are **never committed**. The InfraEnv iPXE URL is access-bearing and is retained in local Terraform state. Keep that state secure.

**Validation status:** In the November 2026 Latitude lab, the corrected iPXE path downloaded the RHACM kernel/initrd/rootfs, booted RHCOS, applied Ignition, and registered an Agent. The repeatable scripts and other environments still need independent verification; CI checks Bash syntax and Terraform formatting/validation. See [troubleshooting](docs/troubleshooting.md).

## References

[Latitude API projects](https://www.latitude.sh/docs/api-reference/get-projects) · [Latitude Terraform](https://registry.terraform.io/providers/latitudesh/latitudesh/latest) · [Cloudflare DNS API](https://developers.cloudflare.com/api/resources/dns/subresources/records/) · [RHACM](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/) · [OpenShift SNO](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_a_single_node/index)
