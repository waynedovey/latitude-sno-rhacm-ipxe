# Troubleshooting and safety checks

## Before provisioning

- Check the selected Latitude location actually stocks the chosen server plan and supports Custom Images/iPXE; the published US$0.41/hr is a *global starting price*, not a guaranteed regional quote.
- Use hourly billing. Latitude Terraform's provider defaults to monthly unless billing is explicitly set.
- m4.metal.small provides 6 *physical* cores / 12 SMT threads. Verify SMT/8+ logical CPUs once the Agent is discovered. Upgrade to f4.metal.small if it fails.
- Confirm the RHACM hub has Central Infrastructure Management and an existing ClusterImageSet compatible with the hub and desired OCP release.
- Keep config/lab.env, pull secrets, API tokens, Terraform state, and plan files out of Git.

## iPXE returns to network boot / never discovers

1. Inspect Latitude's server console: UEFI/BIOS, active NIC, iPXE DHCP lease, and ability to access HTTP(S) URLs.
2. Check RHACM: oc -n CLUSTER get infraenv CLUSTER -o yaml, and the assisted-service / assisted-image-service pods.
3. If HTTPS is not supported by the boot firmware, review RHACM AgentServiceConfig spec.iPXEHTTPRoute (HTTP vs HTTPS), but avoid exposing signed installer artifacts on untrusted networks.
4. Latitude's public DHCP/static-IP behaviour depends on the facility. If the live agent doesn't receive the correct network settings, configure an NMStateConfig on the hub and reference it in InfraEnv *before rebooting the discovery environment*.
5. The InfraEnv iPXE URL is access-bearing and may expire. Recreate/retrieve it when needed. Changing the Terraform ipxe field after deployment is intentionally blocked because it could reinstall the server.

## Agent is discovered but validation fails

- Run make discover and inspect CPU count, RAM and disk eligibility. Make sure you used the *Agent inventory disk ID* in INSTALL_DISK_ID.
- Review oc -n CLUSTER describe agent AGENT and oc -n CLUSTER get agentclusterinstall CLUSTER -o yaml.
- Check MACHINE_NETWORK_CIDR matches the *actual* assigned NIC network and NODE_IP. Verify DNS A for api, api-int, and wildcard *.apps under CLUSTER.BASE_DOMAIN.
- The platformType None choice avoids automatic BMC and separate API/ingress VIPs. It uses the SNO node's static public IP with those three DNS records; verify ingress/API reachability and installation supportability for your specific provider.
- If the IP changes after the discovery boot, fix Latitude static/DHCP reservation first; do not continue installation.
- A failed installation validation leaves Agent approved=false. Correct the problem before retrying.

## After installation / charges

- iPXE BootOrderControl should return the machine to local-disk boot after provisioning; if it loops, review Latitude boot order.
- Run make status for hub progress. Check OpenShift API TCP 6443 and ingress TCP 80/443 from clients.
- make destroy terminates the Latitude instance and permanently removes its data; it does not purge RHACM objects.
- If Terraform state is lost, use the Latitude dashboard to locate and stop the server. Never assume billing stopped merely because RHACM cluster resources were removed.

## Sources

- https://www.latitude.sh/pricing
- https://registry.terraform.io/providers/latitudesh/latitudesh/latest
- https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html-single/clusters/index
- https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_a_single_node/index
