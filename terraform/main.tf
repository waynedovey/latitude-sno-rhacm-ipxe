terraform {
  required_version = ">= 1.6.0"

  required_providers {
    latitudesh = {
      source  = "latitudesh/latitudesh"
      version = "~> 4.6.0"
    }
  }
}

provider "latitudesh" {
  auth_token = var.latitude_auth_token
}

resource "latitudesh_server" "sno" {
  project          = var.project
  site             = var.site
  plan             = var.plan
  hostname         = var.hostname
  operating_system = "ipxe"
  ipxe             = var.ipxe_script
  billing          = "hourly"

  # Prevent Terraform from silently reinstalling/erasing the running SNO.
  allow_reinstall = false
}
