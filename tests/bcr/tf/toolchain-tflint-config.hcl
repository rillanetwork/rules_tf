# The toolchain-wide tflint config, which is what the extension reads to learn
# which rulesets to mirror. Distinct from my-tflint-config.hcl, which individual
# targets pass as a per-module override and which the extension never sees.
config {
    format = "compact"
    call_module_type = "local"
    force = false
    disabled_by_default = false
}

# Bundled into the tflint binary: named by no source, so nothing to download.
# The extension must skip it rather than report it unresolvable.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# A ruleset that is downloaded: the extension resolves its release sha256 for
# every platform and records them as facts, and the download repository fetches
# the archive against the host's. Chosen for being among the smallest published
# rulesets -- what is under test is the resolution and the install layout, not
# the rules themselves.
plugin "google" {
  enabled = true
  version = "0.39.0"
  source  = "github.com/terraform-linters/tflint-ruleset-google"
}
