resource "random_string" "mirror_json_test" {
  length  = 8
  special = false
}

resource "null_resource" "mirror_json_test" {
}
