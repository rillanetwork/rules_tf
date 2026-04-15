resource "random_string" "mirror_json_test" {
  length = 8
}

resource "null_resource" "mirror_json_test" {
  triggers = {
    value = random_string.mirror_json_test.result
  }
}
