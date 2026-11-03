variable "latitude_auth_token" {
  type      = string
  sensitive = true
}

variable "project" {
  type = string
}

variable "site" {
  type    = string
  default = "SGP"
}

variable "plan" {
  type    = string
  default = "f4-metal-small"
}

variable "hostname" {
  type    = string
  default = "latitude-sno"
}

variable "ipxe_script" {
  type      = string
  sensitive = true
}
