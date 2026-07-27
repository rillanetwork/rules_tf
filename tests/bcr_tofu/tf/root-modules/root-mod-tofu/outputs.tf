output "value" {
  description = "the generated random string"
  value       = random_string.tofu_test.result
}
