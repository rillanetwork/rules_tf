# Every source shape the mirror handles, so the manifest's matching is covered
# by the suite rather than by hand: a plain registry address, one reaching a
# subdirectory of the same package, and a getter source carrying its own ref.
#
# All three resolve to cloudposse/terraform-null-label, which requires no
# providers, so this costs the mirror nothing beyond the modules themselves.

module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  namespace = "eg"
  name      = "mirrored"
}

# A //subdir entry: installed as the whole package and pointed at from within.
# This one also calls a registry module of its own, so the closure has to be
# expanded under it.
module "exported" {
  source  = "cloudposse/label/null//exports"
  version = "0.25.0"

  namespace = "eg"
  name      = "subdir"
}

# A getter source. terraform-docs splits the trailing "?ref=" into its version
# column, so recomposing the literal is what has to match the mirror here.
module "from_git" {
  source = "git::https://github.com/cloudposse/terraform-null-label.git?ref=0.25.0"

  namespace = "eg"
  name      = "getter"
}
