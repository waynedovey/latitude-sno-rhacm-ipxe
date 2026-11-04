output "server_id" {
  description = "Latitude.sh server ID, used for read-only management IP/CIDR lookup."
  value       = latitudesh_server.sno.id
}

output "plan" {
  value = latitudesh_server.sno.plan
}

output "site" {
  value = latitudesh_server.sno.site
}


output "public_ipv4" {
  description = "Latitude's assigned primary IPv4, computed by the provider."
  value       = latitudesh_server.sno.primary_ipv4
}
