# Latitude SNO — OpenShift on Latitude.sh

Deploy **single-node OpenShift 4.22** on Latitude.sh bare metal with an existing **RHACM/MCE hub** and iPXE. Optionally add **LVM Storage** and **OpenShift Virtualization**.

Default lab: `latitude-sno.digitaldovey.com` · Latitude Singapore (`SGP`) · `f4-metal-small` · hourly billing.

## 1. Prepare

You need:

- An RHACM/MCE hub with **Central Infrastructure Management**; `oc` logged into that hub.
- macOS tools: `oc`, Terraform ≥1.6, `jq`, `curl`, `dig`.
- Latitude and Cloudflare API tokens, a Red Hat pull secret, and an SSH public key.
- Cloudflare DNS for `digitaldovey.com` (token permissions: Zone Read + DNS Edit).

```bash
git clone https://github.com/waynedovey/latitude-sno-rhacm-ipxe.git
cd latitude-sno-rhacm-ipxe

mkdir -p private
cp config/lab.env.example config/lab.env
oc get clusterimagesets
# Set CLUSTER_IMAGE_SET in config/lab.env to the desired image set.

# Place your credentials/keys in:
# private/pull-secret.json
# private/id_ed25519.pub

export LATITUDE_AUTH_TOKEN="YOUR_LATITUDE_TOKEN"
export CF_API_TOKEN="YOUR_CLOUDFLARE_TOKEN"
```

Leave `NODE_IP`, `MACHINE_NETWORK_CIDR`, `INSTALL_DISK_ID`, `AGENT_ID`, `LVMS_DISK_BY_ID`, and `SNO_KUBECONFIG` blank. The scripts detect hardware/network details; post-install commands use the active `oc` context. Keep `config/lab.env` and `private/` out of Git.

## 2. Deploy SNO

```bash
make check
make prepare-hub

# Provisions hourly-billed Latitude hardware.
CONFIRM_COST=YES make provision

# Wait until exactly one Agent appears.
make discover

# Creates unproxied API, API-int and *.apps DNS records.
CONFIRM_DNS=YES make dns

# Installs OpenShift onto the selected NVMe disk.
CONFIRM_INSTALL=YES make install

make status
```

**Disk warning:** `make install` picks the lowest eligible stable NVMe by-id; eligibility does **not** mean the disk is empty. Review `make discover` before confirming installation. Override `INSTALL_DISK_ID` if needed.

**Network:** The public IP and actual subnet come from the Latitude API, not a guessed CIDR. Cloudflare records are DNS-only. `make install` checks DNS before approving the Agent.

## 3. Add LVM Storage and OpenShift Virtualization

When the cluster is installed, retrieve its kubeconfig **while `oc` still points to the hub**:

```bash
secret=$(oc -n latitude-sno get clusterdeployment latitude-sno \
  -o jsonpath='{.status.clusterMetadata.adminKubeconfigSecretRef.name}')

oc -n latitude-sno get secret "$secret" \
  -o jsonpath='{.data.kubeconfig}' | base64 -D > private/latitude-sno.kubeconfig
chmod 600 private/latitude-sno.kubeconfig

# Switch to the installed SNO for all following commands.
export KUBECONFIG="$PWD/private/latitude-sno.kubeconfig"
oc get nodes
```

Install the operators, check the unused disk, then create LVMS:

```bash
CONFIRM_SNO_OPERATORS=YES make sno-operators
make sno-disk-check
CONFIRM_LVMS_DISK=YES make sno-lvms-disk

oc get storageclass
oc get lvmcluster -n openshift-storage
oc get hyperconverged -n openshift-cnv
```

The LVMS script uses a stable by-id link and proceeds only when **one blank whole NVMe** is found. Check its identity before confirming: allocating it makes any existing data unusable. The local StorageClass is `lvms-vg1` (single-node storage, **not HA**). After LVMS is configured, don't rerun the blank-disk check.

## Optional: AWS hub image download fix

If the RHACM hub is on AWS and the RHCOS rootfs download is **truncated**, run these **after `make prepare-hub` and before `make provision`**:

```bash
# Set HUB_PUBLIC_ROUTE53_ZONE_ID in config/lab.env first.
CONFIRM_IMAGE_NLB=YES make image-nlb
make image-check
CONFIRM_IMAGE_DNS=YES make image-route53
```

This provisions a separate, billable NLB for the hub image-service route; it does **not** replace the hub's wildcard ingress. See [AWS NLB troubleshooting](docs/troubleshooting.md#aws-hub-image-download-is-truncated) for prerequisites, checks, and recovery.

## Cleanup

```bash
# Terminates the hourly-billed Latitude server.
CONFIRM_DESTROY=YES make destroy
```

This does **not** delete RHACM resources, Cloudflare records, or an optional AWS NLB/Route53 record.

For errors and safety details, see [Troubleshooting](docs/troubleshooting.md). All destructive and billable steps require explicit confirmation.
