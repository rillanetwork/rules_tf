variable "secret" {
  type      = string
  sensitive = true
}

variable "plain" {
  type = string
}

resource "terraform_data" "child" {
  input = [var.plain, var.secret]
}

output "secret_out" {
  value     = var.secret
  sensitive = true
}
