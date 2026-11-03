output "server_id" {
  description = "Latitude.sh server ID. Use the Latitude dashboard to read assigned public IP/network."
  value       = latitudesh_server.sno.id
}

output "plan" {
  value = latitudesh_server.sno.plan
}

output "site" {
  value = latitudesh_server.sno.site
}
