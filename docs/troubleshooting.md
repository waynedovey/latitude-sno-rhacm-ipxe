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

## Cloudflare DNS

- `make dns` needs `CF_API_TOKEN` with **Zone:Read** and **DNS:Edit**, plus `NODE_IP` in `config/lab.env`.
- Cloudflare zone must belong to `BASE_DOMAIN=digitaldovey.com`; `CF_ZONE_ID` can be supplied if auto-lookup is unavailable.
- Use **DNS only / grey cloud** for API, API-int, and wildcard apps records. Do **not** proxy the OpenShift API through Cloudflare.
- If the script finds an existing record with a different IP or proxy setting, inspect it first; use `ALLOW_DNS_REPLACE=YES CONFIRM_DNS=YES make dns` only when the overwrite is intentional.
- Wait for nameserver delegation and record propagation. Check `dig +short api.latitude-sno.digitaldovey.com A`, `dig +short api-int.latitude-sno.digitaldovey.com A`, and `dig +short test.apps.latitude-sno.digitaldovey.com A`.
- `make destroy` intentionally **does not delete** DNS records, avoiding surprise removal of records that may have been repointed.

## Agent validation and installation

- `make discover` displays CPU, memory, Agent disk IDs. Use a discovered `INSTALL_DISK_ID`.
- `MACHINE_NETWORK_CIDR` must contain the **real** `NODE_IP`.
- All three public DNS names must resolve to `NODE_IP` before `make install` approves the Agent.
- `platformType: None` uses the SNO node public IP and avoids external BMC/VIP allocation; check reachability and supportability.
- If public IP changes after discovery, fix address stability before continuing.
- Failed host validation leaves the Agent **unapproved**.

## Cost and cleanup

- Latitude Terraform is configured for **hourly** billing. Monitor charges in the Latitude dashboard.
- `CONFIRM_DESTROY=YES make destroy` permanently terminates the server/disk; it does not purge RHACM or Cloudflare.
- If Terraform state is missing, manually destroy the server in Latitude. Do not assume removing RHACM objects stops billing.
