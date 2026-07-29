resource "random_string" "facts_test" {
  length  = 8
  special = false
}

resource "null_resource" "facts_test" {
}
