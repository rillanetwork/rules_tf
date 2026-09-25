# Toolchain-wide tflint config; the extension reads this one to find rulesets
# to mirror, not any per-target override.
config {
    format = "compact"
    call_module_type = "local"
    force = false
    disabled_by_default = false
}

# Built into tflint, so it has no source and the extension skips it.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# A small downloaded ruleset, for a fast test.
plugin "google" {
  enabled = true
  version = "0.39.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
