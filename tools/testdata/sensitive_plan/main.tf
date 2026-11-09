terraform {
  required_providers {
    random = { source = "hashicorp/random", version = "3.3.2" }
  }
}

variable "secret" {
  type      = string
  sensitive = true
}

variable "secret_with_default" {
  type      = string
  sensitive = true
  default   = "DEFAULT-SECRET-VALUE"
}

variable "plain" {
  type = string
}

resource "random_password" "pw" {
  length  = 16
  special = false
  keepers = { rotate = var.plain }
}

resource "terraform_data" "mixed" {
  input = {
    name  = var.plain
    token = var.secret
    other = var.secret_with_default
  }
}

module "child" {
  source = "./child"
  secret = var.secret
  plain  = var.plain
}

output "pw" {
  value     = random_password.pw.result
  sensitive = true
}

output "plain" {
  value = var.plain
}
