"""Terraform's release coordinates, and the repository rule that downloads them."""

load(
    "@rules_tf//tf/toolchains:tf_download.bzl",
    "TF_DOWNLOAD_ATTRS",
    "tf_declare_toolchain_chunk",
    "tf_download_impl",
)

# Also read by the module extension, which resolves the release's sha256 from
# the checksums document and fetches the same binary to verify provider hashes
# with.
URL_TEMPLATE = "https://releases.hashicorp.com/terraform/{version}/{file}"
SHA256SUMS_TEMPLATE = "https://releases.hashicorp.com/terraform/{version}/terraform_{version}_SHA256SUMS"

# HashiCorp signs the checksum document with the release signing subkey
# 374EC75B485913604A831CC7C820C6D5CD27AB87. The neighbouring
# `.72D7468F.sig` is the same signature named by the primary key's id, so
# either file answers the same question and this takes the plain one.
SIGNATURE_TEMPLATE = SHA256SUMS_TEMPLATE + ".sig"

def _download_impl(ctx):
    return tf_download_impl(
        ctx,
        tool = "terraform",
        build_tpl = Label("@rules_tf//tf/toolchains/terraform:BUILD.toolchain.tpl"),
        url_template = URL_TEMPLATE,
    )

terraform_download = repository_rule(
    implementation = _download_impl,
    attrs = TF_DOWNLOAD_ATTRS,
)

DECLARE_TOOLCHAIN_CHUNK = tf_declare_toolchain_chunk("terraform")
