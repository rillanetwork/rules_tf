load(
    "@rules_tf//tf/toolchains:utils.bzl",
    "TF_DOWNLOAD_ATTRS",
    "tf_declare_toolchain_chunk",
    "tf_download_impl",
)

def _download_impl(ctx):
    tf_download_impl(
        ctx,
        tool = "tofu",
        build_tpl = Label("@rules_tf//tf/toolchains/tofu:BUILD.toolchain.tpl"),
        url_template = "https://github.com/opentofu/opentofu/releases/download/v{version}/{file}",
        sha256sums_template = "https://github.com/opentofu/opentofu/releases/download/v{version}/tofu_{version}_SHA256SUMS",
    )

tofu_download = repository_rule(
    implementation = _download_impl,
    attrs = TF_DOWNLOAD_ATTRS,
)

DECLARE_TOOLCHAIN_CHUNK = tf_declare_toolchain_chunk("tofu")
