resource "random_string" "tofu_test" {
  length  = 8
  special = false
}

resource "null_resource" "tofu_test" {
}
