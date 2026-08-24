# Calls a local module that itself calls mirrored remote modules, twice under
# two names. Terraform keys those by call path, so the manifest must carry
# "first.label", "second.label" and so on -- keys no BUILD file knows.
module "first" {
  source = "../../modules/mod-remote"
}

module "second" {
  source = "../../modules/mod-remote"
}
