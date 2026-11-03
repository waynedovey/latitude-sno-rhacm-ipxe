# Latitude.sh OpenShift SNO via RHACM + iPXE

Provision an **hourly-billed Latitude.sh bare-metal server** with Terraform, boot the **existing RHACM hub's** Assisted Installer via iPXE, then install a single-node OpenShift spoke. No Metal3/BMC dependency and no second RHACM hub.

## Hardware and cost

| Plan | CPU | RAM | Disks | Advertised starting price |
| --- | --- | --- | --- | --- |
| **m4.metal.small** (default) | 6 cores / 12 SMT threads | 48 GB | 2 × 960 GB NVMe | **US$0.41/hour** |
| f4.metal.small (fallback) | 12 cores / 24 threads | 96 GB | 2 × 960 GB NVMe | US$0.55/hour |

OpenShift SNO requires at least 8 vCPUs, 16 GB RAM, and 120 GB disk. **m4.small only qualifies if SMT is enabled and the Assisted Installer sees at least 8 logical CPUs.** If its hardware checks fail, destroy the server and choose f4.small. Rates are *starting* rates, not a real-time location quote. Check plan stock, the exact hourly price, and iPXE availability for your Latitude site *before* approving provisioning. Hourly billing is explicitly configured (the Terraform provider otherwise defaults to monthly).

## Quick start (macOS)

Prerequisites: Terraform >= 1.6, oc authenticated to an existing RHACM/MCE hub with Central Infrastructure Management enabled, jq, dig, curl, and a Red Hat pull secret. You also need a Latitude API token/project and a DNS zone you control.

~~~bash
git clone https://github.com/waynedovey/latitude-sno-rhacm-ipxe.git
cd latitude-sno-rhacm-ipxe
mkdir -p private
cp config/lab.env.example config/lab.env
# Edit config/lab.env: cluster DNS, Latitude project + site, chosen ClusterImageSet.
# Save pull-secret JSON to private/pull-secret.json and SSH public key to private/id_ed25519.pub.
export LATITUDE_AUTH_TOKEN="YOUR_TOKEN_IN_LOCAL_SHELL"
make check
make prepare-hub
CONFIRM_COST=YES make provision
make discover
~~~

After the server is deployed, retrieve its public IP and network CIDR from Latitude. Set NODE_IP, MACHINE_NETWORK_CIDR and the eligible INSTALL_DISK_ID reported by make discover in config/lab.env. Add public DNS records:

- api.latitude-sno.example.com → NODE_IP
- api-int.latitude-sno.example.com → NODE_IP
- *.apps.latitude-sno.example.com → NODE_IP

Substitute your actual CLUSTER_NAME/BASE_DOMAIN. The node must reach the RHACM-assisted service and public image registries, and clients must reach TCP 6443, 80, and 443.

~~~bash
CONFIRM_INSTALL=YES make install
make status
# When finished, stop hourly billing:
CONFIRM_DESTROY=YES make destroy
~~~

**Do not run make install before selecting the correct installation disk.** The disk will be overwritten by OpenShift. The scripts will not automatically modify DNS, approve an Agent, create a Latitude server, or destroy a server without the relevant operator step/confirmation.

## How it works

1. **prepare-hub:** creates only a namespaced pull-secret and InfraEnv on the existing RHACM hub; waits for status.bootArtifacts.ipxeScript.
2. **provision:** hands the short-lived RHACM iPXE URL to Latitude's Terraform provider with operating_system=ipxe and hourly billing.
3. **discover:** examines the discovered Agent's CPU/memory/disks/network status; verify its installation disk and public IP.
4. **install:** checks DNS, machine network, Agent inventory, selected disk and ClusterImageSet; creates AgentClusterInstall + ClusterDeployment with platformType None (no additional VIPs/BMC); binds and approves only the selected Agent.
5. **status/destroy:** inspect the RHACM install and release the billed server when finished.

The iPXE URL is an access-bearing URL and is stored in local Terraform state. State, plan files, tokens, kubeconfigs, pull secrets and lab settings must never be committed. Use a secure local workspace or encrypted backend. The public repository has **no** operational credentials.

This project is an initial repeatable lab implementation, not a claim that Latitude's DHCP/iPXE behaviour has been validated in every metro. Network interface, firmware, public-IP configuration and boot-to-disk behaviour must be tested on the selected site. For static networking / NMState, adapt InfraEnv before provisioning.

## Further reading

- [RHACM Assisted Installer / InfraEnv](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index)
- [OpenShift 4.21 SNO requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_a_single_node/index)
- [Latitude Terraform provider](https://registry.terraform.io/providers/latitudesh/latitudesh/latest)
- [Latitude metal prices](https://www.latitude.sh/pricing)
- [Troubleshooting](docs/troubleshooting.md)
