# Latitude.sh SNO — RHACM + iPXE + Cloudflare

Deploy a **single-node OpenShift (SNO)** cluster on Latitude.sh bare metal using an **existing RHACM hub**, Terraform, and Assisted Installer iPXE. Cloudflare DNS is configured after the server receives its public IP.

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

Requires `oc` logged into an RHACM/MCE hub with Central Infrastructure Management, Terraform ≥1.6, `jq`, `curl`, `dig`, a Red Hat pull secret, and Cloudflare DNS for the domain.

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
CONFIRM_COST=YES make provision
make discover
```

The scripts resolve the Latitude project display name to its project ID using the Latitude API. If preferred, set `LATITUDE_PROJECT` to a `proj_...` ID or slug directly. No server order occurs without `CONFIRM_COST=YES`.

When the Agent appears, set the real `NODE_IP`, `MACHINE_NETWORK_CIDR`, and `INSTALL_DISK_ID` in your ignored `config/lab.env` (use the discovered **disk ID**, not a guessed device path).

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

## Workflow

1. `make prepare-hub`: creates a pull secret and InfraEnv in the existing RHACM hub, producing an iPXE boot URL.
2. `make provision`: Terraform orders the Latitude server in **SGP**, boots RHACM iPXE and uses **hourly** billing.
3. `make discover`: inspects the Agent, disks and hardware checks.
4. `make dns`: creates the three Cloudflare records for the assigned IP.
5. `make install`: creates the AgentClusterInstall/ClusterDeployment and installs SNO; `make status` monitors it.
6. `make destroy`: releases the billed server (does not automatically delete RHACM resources or Cloudflare DNS).

`config/lab.env`, API tokens, pull secrets, kubeconfigs and Terraform state/plans are **never committed**. The InfraEnv iPXE URL is access-bearing and is retained in local Terraform state. Keep that state secure.

**Validation status:** Terraform and Bash syntax are CI-checked. Latitude iPXE boot, site availability, network setup and Cloudflare API calls still require a live end-to-end test. See [troubleshooting](docs/troubleshooting.md).

## References

[Latitude API projects](https://www.latitude.sh/docs/api-reference/get-projects) · [Latitude Terraform](https://registry.terraform.io/providers/latitudesh/latitudesh/latest) · [Cloudflare DNS API](https://developers.cloudflare.com/api/resources/dns/subresources/records/) · [RHACM](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/) · [OpenShift SNO](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_a_single_node/index)
