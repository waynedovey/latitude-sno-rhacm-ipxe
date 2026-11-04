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

When the Agent appears, **no IP/CIDR/disk-ID editing is needed**. `make dns` and `make install` query Latitude's assigned management IPv4 and CIDR for the exact Terraform-managed server. `make install` selects the lowest eligible, stable NVMe by-id from Agent inventory. Review the choice printed by `make discover` and `make install` carefully before setting `CONFIRM_INSTALL=YES`—both disks could contain important data even when the installer calls them eligible. To choose a different disk, set `INSTALL_DISK_ID` explicitly.

The following values are **optional overrides**, not required configuration: `NODE_IP`, `MACHINE_NETWORK_CIDR`, `INSTALL_DISK_ID`, and `AGENT_ID`. Auto-discovery intentionally fails closed if the server's management IP or eligible disk cannot be identified unambiguously. Keep the Latitude API token available for DNS and installation; scripts never assume a subnet based on the hardware plan.

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

`make dns` automatically reads the exact public IPv4 and machine subnet assigned by Latitude using the provisioned server ID. It is idempotent and **refuses to overwrite** an existing record pointing elsewhere or with the Cloudflare proxy enabled unless you explicitly pass `ALLOW_DNS_REPLACE=YES` as well. It never modifies other domains or records. Ensure your domain's nameservers actually delegate to Cloudflare and allow DNS propagation before installing.

### Install and clean up

```bash
CONFIRM_INSTALL=YES make install
make status

# When finished, terminate hourly-billed hardware:
CONFIRM_DESTROY=YES make destroy
```

**Important:** Installation overwrites the automatically selected NVMe disk, which is not necessarily empty. Read the selected by-id path in the preflight output and override it if necessary. Ensure the node's public IPv4 stays stable, the node reaches RHACM and image registries, and clients can reach TCP **6443 / 80 / 443**. The install script checks public DNS resolution before approving the Agent. The explicit `CONFIRM_INSTALL=YES` safeguard remains mandatory.

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

If the secret reference is missing, the Assisted Installer may still be finishing. For post-install commands, either **switch your current `oc` context to the new SNO** or set `SNO_KUBECONFIG=private/latitude-sno.kubeconfig` as an optional override (in your shell or ignored `config/lab.env`). You no longer need to configure the path for each run. Every post-install script verifies the exact SNO API URL, version, and single Ready node and **rejects the RHACM hub context**.

### 2. Install both operators (does not claim storage)

```bash
# First select the installed SNO in your current oc context.
oc config use-context YOUR_SNO_CONTEXT
CONFIRM_SNO_OPERATORS=YES make sno-operators
oc get csv -n openshift-storage
oc get csv -n openshift-cnv
oc get hyperconverged -n openshift-cnv
```

If you prefer not to change context, set `SNO_KUBECONFIG=private/latitude-sno.kubeconfig` once in your shell or ignored config file; in that case use `oc --kubeconfig=private/latitude-sno.kubeconfig` for the verification commands. No context switch is needed when your current `oc` connection already points to the SNO.

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

The disk-ID setting is now **optional**. The script probes the installed SNO and selects a spare disk **only when exactly one entire NVMe is partition-free, unmounted, and has no detectable signatures**. If there is more than one candidate—or none—it stops and requires manual verification. This deliberately avoids using unstable `/dev/nvme0n1` numbering.

Run the read-only device check (no data changed):

```bash
make sno-disk-check
```

The output prints the selected **stable by-id path**. Independently verify its device identity and that it contains no useful data before continuing: even an apparently blank device can contain undetectable data. You may override the choice with `LVMS_DISK_BY_ID=/dev/disk/by-id/nvme-eui.YOUR_VERIFIED_ID`. If the check fails, it creates **no LVMCluster**. After a volume is created, this blank-disk discovery no longer applies; existing LVMCluster storage is left untouched.

### 4. Explicitly allocate the spare NVMe to LVMS

**Only after verifying the drive's physical identity and accepting that allocating it to LVMS will make existing data on the whole disk unusable:**

```bash
CONFIRM_LVMS_DISK=YES make sno-lvms-disk

oc get lvmcluster lvmcluster -n openshift-storage
oc get sc lvms-vg1
oc get pods -n openshift-cnv
```

The generated LVMCluster explicitly chooses **only the checked, stable by-id path**, sets `forceWipeDevicesAndDestroyAllData: false`, and configures an XFS-backed `vg1` with a 90% thin pool and the required `overprovisionRatio: 10`. This 10:1 ratio permits *logical* overprovisioning; it does not increase physical capacity. Monitor thin-pool usage to avoid exhaustion. The local storage class is `lvms-vg1`. Do not automatically force-wipe an unidentified or OS disk.

References: [OpenShift 4.22 LVMS](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/storage/persistent-storage-using-local-storage) and [OpenShift 4.22 Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/virtualization/installing).

## Workflow

1. `make prepare-hub`: creates a pull secret and InfraEnv in the existing RHACM hub, producing an iPXE boot URL.
2. **If the hub's large image download is truncated:** `make image-nlb`, `make image-check`, and `make image-route53` after explicit confirmation; preserves default router and wildcard.
3. `make provision`: Terraform orders the Latitude server in **SGP**, boots RHACM iPXE and uses **hourly** billing.
4. `make discover`: inspects the Agent, eligible disks and hardware checks (IP/CIDR and OS disk selection are automatic). Seeing `APPROVED=false` / `ROLE=auto-assign` initially is normal.
5. `make dns`: looks up Latitude's actual management IPv4/subnet and creates the three Cloudflare records for the assigned IP.
6. `make install`: auto-selects an eligible stable NVMe disk (with an explicit confirmation before erasure), validates the host, creates the AgentClusterInstall/ClusterDeployment, and then approves the Agent; `make status` monitors it.
7. `make destroy`: releases the billed server (does not automatically delete RHACM, NLB, Route53, or Cloudflare resources).

`config/lab.env`, API tokens, pull secrets, kubeconfigs and Terraform state/plans are **never committed**. The InfraEnv iPXE URL is access-bearing and is retained in local Terraform state. Keep that state secure.

**Validation status:** In the November 2026 Latitude lab, the corrected iPXE path downloaded the RHACM kernel/initrd/rootfs, booted RHCOS, applied Ignition, and registered an Agent. The repeatable scripts and other environments still need independent verification; CI checks Bash syntax and Terraform formatting/validation. See [troubleshooting](docs/troubleshooting.md).

## References

[Latitude API projects](https://www.latitude.sh/docs/api-reference/get-projects) · [Latitude Terraform](https://registry.terraform.io/providers/latitudesh/latitudesh/latest) · [Cloudflare DNS API](https://developers.cloudflare.com/api/resources/dns/subresources/records/) · [RHACM](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/) · [OpenShift SNO](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_a_single_node/index)
