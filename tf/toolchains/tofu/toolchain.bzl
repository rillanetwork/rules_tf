"""Tofu's release coordinates, and the repository rule that downloads them."""

load(
    "@rules_tf//tf/toolchains:tf_download.bzl",
    "TF_DOWNLOAD_ATTRS",
    "tf_declare_toolchain_chunk",
    "tf_download_impl",
)

# Also read by the module extension, which resolves the release's sha256 from
# the checksums document and fetches the same binary to verify provider hashes
# with.
URL_TEMPLATE = "https://github.com/opentofu/opentofu/releases/download/v{version}/{file}"
SHA256SUMS_TEMPLATE = "https://github.com/opentofu/opentofu/releases/download/v{version}/tofu_{version}_SHA256SUMS"

def _download_impl(ctx):
    return tf_download_impl(
        ctx,
        tool = "tofu",
        build_tpl = Label("@rules_tf//tf/toolchains/tofu:BUILD.toolchain.tpl"),
        url_template = URL_TEMPLATE,
    )

tofu_download = repository_rule(
    implementation = _download_impl,
    attrs = TF_DOWNLOAD_ATTRS,
)

DECLARE_TOOLCHAIN_CHUNK = tf_declare_toolchain_chunk("tofu")
