"""The repositories that hold mirrored terraform modules.

One repository per package, so that a module reached from several root modules is
fetched once and shared, and so that a package whose bytes cannot be pinned
costs only itself its cacheability rather than costing the whole store.

Each repository takes coordinates the extension has already resolved. Where
those name an archive and its sha256, the fetch is pinned by attributes alone and
the repository declares itself reproducible, which is what admits it to the repo
contents cache. Where they name a source only terraform can reach, the tool runs
here and the repository says so: `repo_metadata(reproducible = True)` would be
claiming the output is identical "even if other untracked conditions change, such
as ... output from running arbitrary executables", which is exactly what it is
not.
"""

load(":registry.bzl", "auth_headers", "new_registry_client", "url_host")

_GET_TIMEOUT = 600

# Written as JSON rather than HCL so that a source containing quotes, braces or
# backslashes needs no escaping of ours.
_ROOT_TF_JSON = """{"module": {"pkg": %s}}"""

_CALL = "pkg"

# Where the package's own files land, in every repository this declares. A
# consumer addresses a module as "<package repo>//:files" and reaches into this
# directory, so the name is part of the layout the store manifest describes.
_PACKAGE_DIR = "module"

_BUILD = """\
\"\"\"Generated: one mirrored terraform module package.\"\"\"

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "files",
    srcs = glob(
        ["{package_dir}/**"],
        exclude = [
            # Version-control metadata is not part of a module, and a git-backed
            # fetch leaves a great deal of it behind.
            "{package_dir}/**/.git/**",
        ],
        allow_empty = False,
    ),
)
"""

def _single_child(ctx, path):
    """Returns the sole directory entry under path, or None.

    An archive published by a forge wraps the tree in one directory whose name
    carries the ref, so the name cannot be predicted from the coordinates but
    the shape can.

    Args:
      ctx: the download repository's `repository_ctx`.
      path: the staging directory to inspect.

    Returns:
      The single child's path, or None when there is not exactly one.
    """
    children = ctx.path(path).readdir()
    if len(children) != 1:
        return None

    return children[0]

def _fetch_archive(ctx):
    """Fetches the package from a pinned archive.

    Args:
      ctx: the download repository's `repository_ctx`.

    Returns:
      True when the archive landed, False when it must be left to the tool.
    """

    # Credentials go out only when the archive is served by the registry host
    # itself. A public registry hands back a third-party object store, which
    # must never receive the token.
    headers = {}
    if url_host(ctx.attr.download_url) == ctx.attr.registry_host:
        headers = auth_headers(new_registry_client(ctx), ctx.attr.registry_host)

    # Stated rather than inferred: a forge's archive URL ends in the ref, so
    # there is no suffix for bazel to read the format from.
    res = ctx.download_and_extract(
        url = [ctx.attr.download_url],
        sha256 = ctx.attr.sha256,
        output = "staging",
        type = ctx.attr.archive_type,
        allow_fail = True,
        headers = headers,
    )
    if not res.success:
        return False

    # The wrapping directory is named for the ref, so it is found rather than
    # predicted, and the package is moved out from under it.
    root = _single_child(ctx, "staging")
    if not root:
        fail(("the archive for %s did not unpack to a single directory, so the package root " +
              "cannot be identified: %s") % (ctx.attr.store_key, ctx.attr.download_url))

    ctx.rename(root, _PACKAGE_DIR)
    ctx.delete("staging")
    return True

def _fetch_with_tool(ctx):
    """Fetches the package by asking terraform to install it.

    Reaches whatever go-getter reaches, which is the point: a source this path
    handles is one no archive URL addresses, and reimplementing its scheme would
    be a fidelity gap rather than a feature.

    Args:
      ctx: the download repository's `repository_ctx`.
    """
    ctx.download_and_extract(
        url = [ctx.attr.tool_url],
        sha256 = ctx.attr.tool_sha256,
        output = "tool",
        type = "zip",
    )

    block = {"source": ctx.attr.source}
    if ctx.attr.version:
        block["version"] = ctx.attr.version

    workdir = "get"
    ctx.file(
        workdir + "/root.tf.json",
        _ROOT_TF_JSON % json.encode(block),
        executable = False,
    )

    # The environment is inherited, so credentials for the source reach the tool
    # the way they reach it anywhere else.
    result = ctx.execute(
        [ctx.path("tool/%s" % ctx.attr.tool_name), "-chdir=%s" % ctx.path(workdir), "get"],
        timeout = _GET_TIMEOUT,
    )
    if result.return_code != 0:
        fail("could not fetch %s: `%s get` exited %d.\n%s" % (
            ctx.attr.store_key,
            ctx.attr.tool_name,
            result.return_code,
            result.stderr,
        ))

    installed = "%s/.terraform/modules/%s" % (workdir, _CALL)
    if not ctx.path(installed).exists:
        fail("`%s get` installed nothing for %s" % (ctx.attr.tool_name, ctx.attr.store_key))

    ctx.rename(installed, _PACKAGE_DIR)
    ctx.delete(workdir)
    ctx.delete("tool")

def _tf_module_package_impl(ctx):
    """Fetches one mirrored module package.

    Args:
      ctx: the download repository's `repository_ctx`.

    Returns:
      A `repo_metadata` whose reproducibility reflects how the package was
      fetched, since the two paths make genuinely different promises.
    """
    pinned = False
    if ctx.attr.download_url and ctx.attr.sha256:
        pinned = _fetch_archive(ctx)

    if not pinned:
        _fetch_with_tool(ctx)

    ctx.file("BUILD.bazel", _BUILD.format(package_dir = _PACKAGE_DIR))

    # Reproducible only on the pinned path: those contents are a function of the
    # attributes alone, an archive fetched against a sha256 the extension
    # resolved and passed in. The tool path reaches the network on coordinates
    # terraform interprets, and terraform's own output is not byte-stable -- the
    # same module at the same version has been observed to differ by whether it
    # retained a .git directory -- so it promises nothing of the kind.
    return ctx.repo_metadata(reproducible = pinned)

tf_module_package = repository_rule(
    _tf_module_package_impl,
    attrs = {
        "store_key": attr.string(
            mandatory = True,
            doc = "The package's directory name in the store, used in messages and by the " +
                  "manifest that points root modules at it.",
        ),
        "source": attr.string(
            mandatory = True,
            doc = "The package's source as terraform resolved it, with any subdirectory " +
                  "removed. Used only when the package must be fetched by the tool.",
        ),
        "version": attr.string(
            doc = "The concrete version, for a registry source. Empty for a source that " +
                  "carries its own ref.",
        ),
        "download_url": attr.string(
            doc = "Archive the package can be fetched from, resolved by the extension. When " +
                  "set together with sha256 the fetch is pinned by these attributes alone, " +
                  "which is what lets this repository be reproducible and so cached across " +
                  "workspaces. Empty for a source no archive URL addresses.",
        ),
        "sha256": attr.string(
            doc = "sha256 of the archive. Observed by the extension on first fetch rather " +
                  "than read from a checksum document, because a module registry publishes " +
                  "none: it pins the package against later drift rather than attesting the " +
                  "bytes a publisher signed.",
        ),
        "archive_type": attr.string(
            default = "tar.gz",
            doc = "Format of the archive at download_url. Stated because a forge's archive " +
                  "URL ends in the ref rather than in a recognisable suffix.",
        ),
        "registry_host": attr.string(
            doc = "Registry host the package resolves against, so that credentials are sent " +
                  "to it and never to a third-party object store it redirects to.",
        ),
        "tool_name": attr.string(
            default = "terraform",
            doc = "Name of the binary inside the tool archive.",
        ),
        "tool_url": attr.string(
            doc = "Release archive of the tool that fetches a source no archive URL " +
                  "addresses. Fetched only on that path.",
        ),
        "tool_sha256": attr.string(
            doc = "sha256 of the tool's release archive, resolved by the extension from the " +
                  "release's checksums.",
        ),
    },
)

_STORE_BUILD = """\
\"\"\"Generated: the mirrored terraform module store.\"\"\"

load("@rules_tf//tf/rules:tf-module-store.bzl", "tf_module_store_info")

package(default_visibility = ["//visibility:public"])

tf_module_store_info(
    name = "store",
    packages = {packages},
    entries_json = {entries_json},
)
"""

def _tf_module_store_impl(ctx):
    """Declares the hub that gathers every mirrored package.

    Args:
      ctx: the store repository's `repository_ctx`.

    Returns:
      A `repo_metadata` marking the repository reproducible: it holds no fetched
      bytes, only a BUILD file derived from its attributes.
    """
    packages = json.decode(ctx.attr.packages_json)

    # Each package is reached as a label rather than a path, because only the
    # rule reading them can know the canonical repository name runfiles use.
    labels = {
        store_key: "@%s//:files" % repo
        for store_key, repo in sorted(packages.items())
    }

    # json.encode of an already-encoded string yields a valid Starlark string
    # literal, so the table survives into the generated BUILD unescaped by hand.
    ctx.file("BUILD.bazel", _STORE_BUILD.format(
        packages = json.encode_indent(labels, indent = "        "),
        entries_json = json.encode(ctx.attr.entries_json),
    ))

    return ctx.repo_metadata(reproducible = True)

tf_module_store = repository_rule(
    _tf_module_store_impl,
    attrs = {
        "packages_json": attr.string(
            mandatory = True,
            doc = "JSON object mapping each package's store key to the repository holding " +
                  "it, as the extension declared them.",
        ),
        "entries_json": attr.string(
            mandatory = True,
            doc = "JSON object mapping each declared module entry to its source and the " +
                  "closure terraform resolved for it, each closure member naming the store " +
                  "key of the package that holds it.",
        ),
    },
)
