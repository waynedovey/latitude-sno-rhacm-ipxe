# Troubleshooting and safety

## Before provisioning

- In Latitude Singapore (`SGP`), confirm `f4.metal.small` availability, current **hourly** price, and Custom Images/iPXE support. `f4-metal-small` is the plan API slug.
- `LATITUDE_PROJECT="Red Hat SSA Sandbox"` is a **display name**. The scripts resolve it via `GET /projects`. If lookup fails, use a `proj_...` ID or project slug.
- Confirm RHACM Central Infrastructure Management is enabled and the ClusterImageSet is valid.
- Keep tokens, pull secret, local config, and Terraform state out of Git.

## iPXE does not discover an Agent

1. Inspect the Latitude console, NIC/DHCP settings, UEFI boot, and HTTPS access.
2. Check `oc -n latitude-sno get infraenv latitude-sno -o yaml` and the assisted-service pods on the RHACM hub.
3. If firmware cannot fetch HTTPS, review InfraEnv iPXE URL scheme and RHACM AgentServiceConfig settings, weighing HTTP exposure risks.
4. The public-IP network configuration varies by site. Use NMStateConfig on InfraEnv **before** provisioning if DHCP does not configure the interface.
5. Verify the discovery iPXE URL has not expired, and that boot order switches to the local disk after installation.

## AWS hub image download is truncated

Typical symptoms: the Latitude server fetches the RHACM kernel and initrd but stops during the RHCOS live PXE rootfs download; on the boot console you may see `coreos-livepxe-rootfs.service` fail, `curl: (18)`, or an unexpectedly small response. This is a hub ingress/load-balancer issue, not necessarily an iPXE syntax or firmware error.

1. Confirm the current InfraEnv URLs without publishing any token-bearing URLs in chat or logs:
   ```bash
   oc -n latitude-sno get infraenv latitude-sno \
     -o json | jq '.status.bootArtifacts | {kernel,rootfs,ipxeScript}'
   ```
2. If the hub's wildcard routes through a Classic Load Balancer and the image transfer is truncated, isolate the image service via a dedicated NLB on the same ingress pods. Use `CONFIRM_IMAGE_NLB=YES make image-nlb`. This **does not** modify `router-default`.
3. Set `AWS_REGION`, `HUB_PUBLIC_ROUTE53_ZONE_ID`, and `IMAGE_NLB_SERVICE` in `config/lab.env`. Use `make image-check` to verify both TCP listeners, corresponding healthy nodePort target groups, and an entire rootfs transfer through the NLB **before** DNS changes.
4. Then use `CONFIRM_IMAGE_DNS=YES make image-route53` to create the **specific** image-service A Alias in the public AWS Route53 hub zone. The existing wildcard `*.apps.hub...` stays untouched. Check `aws route53 get-change --id ...` (INSYNC) and `dig @1.1.1.1 +short <image-host>`.
5. Retry the Latitude iPXE boot only after the full rootfs passes. Do not reboot a host while it is already installing or fetching artifacts.

If `oc describe svc router-nlb-test` shows `SyncLoadBalancerFailed` with `DuplicateTargetGroupName`, inspect the NLB configuration and ensure `externalTrafficPolicy: Local`. The lab's initial NLB had only listener 80, and adding HTTPS 443 originally failed with target-group conflicts. With Local traffic policy, AWS reconciled both listeners and distinct healthy TCP target groups. Do not manually delete a target group attached to a live NLB.

The dedicated NLB has ongoing AWS charges. The scripts intentionally do **not** delete it or its Route53 record on `make destroy`. Preserve the original wildcard/CLB unless you have a separate ingress migration plan.

## Latitude iPXE may boot HookOS first

Latitude's default provisioning chain may boot **Tinkerbell HookOS / LinuxKit** into a root shell before switching to your custom RHACM iPXE script. That screen alone does not mean RHCOS installation failed. Look at the iPXE console for the `assisted-service`, `pxe-initrd`, and `kernel` downloads; then watch RHCOS and Ignition start.

A successful RHCOS boot may show `Ignition: user-provided config was applied` and a login prompt. Discovery is only confirmed when an **Agent appears**:
```bash
oc -n latitude-sno get agents -w
make discover
```
Initially `APPROVED=false` and `ROLE=auto-assign` are normal. Do not manually approve the Agent; `make install` validates hardware, disk choice, network/DNS and cluster objects first.

## Cloudflare DNS

- `make dns` needs `CF_API_TOKEN` with **Zone:Read** and **DNS:Edit**; it reads the provisioned server's public IP and subnet from Latitude. Set `NODE_IP` only as a verified override.
- Cloudflare zone must belong to `BASE_DOMAIN=digitaldovey.com`; `CF_ZONE_ID` can be supplied if auto-lookup is unavailable.
- Use **DNS only / grey cloud** for API, API-int, and wildcard apps records. Do **not** proxy the OpenShift API through Cloudflare.
- If the script finds an existing record with a different IP or proxy setting, inspect it first; use `ALLOW_DNS_REPLACE=YES CONFIRM_DNS=YES make dns` only when the overwrite is intentional.
- Wait for nameserver delegation and record propagation. Check `dig +short api.latitude-sno.digitaldovey.com A`, `dig +short api-int.latitude-sno.digitaldovey.com A`, and `dig +short test.apps.latitude-sno.digitaldovey.com A`.
- `make destroy` intentionally **does not delete** DNS records, avoiding surprise removal of records that may have been repointed.

## Agent validation and installation

- `make discover` displays CPU, memory, and Agent disk IDs. `make install` automatically selects the lowest eligible stable NVMe by-id; inspect the selection carefully before confirming, and override `INSTALL_DISK_ID` when needed.
- The CIDR is retrieved from Latitude and must contain the **real** `NODE_IP`; do not guess the prefix.
- All three public DNS names must resolve to `NODE_IP` before `make install` approves the Agent.
- `platformType: None` uses the SNO node public IP and avoids external BMC/VIP allocation; check reachability and supportability.
- If public IP changes after discovery, fix address stability before continuing.
- Failed host validation leaves the Agent **unapproved**.

## Cost and cleanup

- Latitude Terraform is configured for **hourly** billing. Monitor charges in the Latitude dashboard.
- `CONFIRM_DESTROY=YES make destroy` permanently terminates the server/disk; it does not purge RHACM or Cloudflare.
- If Terraform state is missing, manually destroy the server in Latitude. Do not assume removing RHACM objects stops billing.
