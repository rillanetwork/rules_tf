resource "random_string" "verified_test" {
  length  = 8
  special = false
}

resource "null_resource" "verified_test" {
}
