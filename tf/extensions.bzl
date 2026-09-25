"""The tf_repositories module extension, which declares the toolchains."""

load("@rules_tf//tf:toolchains.bzl", "tf_toolchains")
load("@rules_tf//tf:versions.bzl", "TFDOC_VERSION", "TFLINT_VERSION")
load("@rules_tf//tf/toolchains:checksums.bzl", "resolve_tool_sha256")
load("@rules_tf//tf/toolchains:facts.bzl", "MIRROR_PLATFORMS", "dirhash_fact_key")
load(
    "@rules_tf//tf/toolchains:provider_locks.bzl",
    "collect_provider_dirhashes",
    "enforce_lock_coverage",
    "fetch_lock_tool",
    "lock_providers",
    "merge_provider_locks",
    "parse_provider_locks",
    "unverified_packages",
    "verify_provider_hashes",
)
load(
    "@rules_tf//tf/toolchains:provider_mirror.bzl",
    "mirror_manifest",
    "parse_mirror_entries",
    "resolve_providers",
)
load("@rules_tf//tf/toolchains:registry.bzl", "DEFAULT_REGISTRY")
load(
    "@rules_tf//tf/toolchains/terraform:toolchain.bzl",
    "terraform_download",
    TERRAFORM_SHA256SUMS_TEMPLATE = "SHA256SUMS_TEMPLATE",
    TERRAFORM_URL_TEMPLATE = "URL_TEMPLATE",
)
load("@rules_tf//tf/toolchains/tfdoc:toolchain.bzl", "tfdoc_download")
load("@rules_tf//tf/toolchains/tflint:toolchain.bzl", "tflint_download")
load(
    "@rules_tf//tf/toolchains/tofu:toolchain.bzl",
    "tofu_download",
    TOFU_SHA256SUMS_TEMPLATE = "SHA256SUMS_TEMPLATE",
    TOFU_URL_TEMPLATE = "URL_TEMPLATE",
)

def detect_host_platform(ctx):
    """Returns the host's (os, arch) pair, in the spelling terraform releases use.

    Args:
      ctx: a module_ctx or repository_ctx, for its `os` field.

    Returns:
      An (os, arch) tuple, e.g. ("darwin", "arm64").
    """
    os = ctx.os.name
    if os == "mac os x":
        os = "darwin"
    elif os.startswith("windows"):
        os = "windows"

    arch = ctx.os.arch
    if arch == "aarch64":
        arch = "arm64"
    elif arch == "x86_64":
        arch = "amd64"

    return os, arch

def _repo_name(*, module, tool, index, suffix = ""):
    # Keep the version out of the repository name if possible to prevent unnecessary rebuilds when
    # it changes.
    return "{name}_{version}_download_{tool}_{index}{suffix}".format(
        # "main_" is not a valid module name and thus can't collide.
        name = module.name or "main_",
        version = module.version,
        tool = tool,
        index = index,
        suffix = suffix,
    )

def _tf_repositories(ctx):
    host_detected_os, host_detected_arch = detect_host_platform(ctx)

    host_platform = "%s_%s" % (host_detected_os, host_detected_arch)
    platforms = MIRROR_PLATFORMS + [
        p
        for p in [host_platform]
        if p not in MIRROR_PLATFORMS
    ]

    tflint_toolchains = []
    tfdoc_toolchains = []
    terraform_toolchains = []
    tofu_toolchains = []
    repo_mirrors = {}
    repo_hashes = {}

    facts = {}

    for module in ctx.modules:
        for index, version_tag in enumerate(module.tags.download):
            tf_repo_name = _repo_name(
                module = module,
                tool = "tf",
                index = index,
                suffix = "_{}_{}".format(host_detected_os, host_detected_arch),
            )
            tfdoc_repo_name = _repo_name(
                module = module,
                tool = "tfdoc",
                index = index,
                suffix = "_{}_{}".format(host_detected_os, host_detected_arch),
            )
            tfdoc_download(
                name = tfdoc_repo_name,
                version = version_tag.tfdoc_version,
                os = host_detected_os,
                arch = host_detected_arch,
            )
            tfdoc_toolchains.append(tfdoc_repo_name)

            tflint_repo_name = _repo_name(
                module = module,
                tool = "tflint",
                index = index,
                suffix = "_{}_{}".format(host_detected_os, host_detected_arch),
            )
            tflint_download(
                name = tflint_repo_name,
                version = version_tag.tflint_version,
                os = host_detected_os,
                arch = host_detected_arch,
                config = version_tag.tflint_config,
            )

            tflint_toolchains.append(tflint_repo_name)

            if version_tag.mirror_json:
                mirror = json.decode(ctx.read(version_tag.mirror_json))
            else:
                mirror = version_tag.mirror

            if mirror == None:
                fail("module {} is missing both mirror and mirror_json attributes; one must be set".format(module.name))

            packages, tag_facts, resolve_errors = resolve_providers(
                ctx,
                parse_mirror_entries(mirror),
                DEFAULT_REGISTRY[version_tag.use_tofu],
                host_detected_os,
                host_detected_arch,
                ctx.facts,
            )
            facts.update(tag_facts)

            tool = "tofu" if version_tag.use_tofu else "terraform"
            tool_sha256, tool_facts, tool_error = resolve_tool_sha256(
                ctx,
                tool,
                version_tag.version,
                host_detected_os,
                host_detected_arch,
                ctx.facts,
                TOFU_SHA256SUMS_TEMPLATE if version_tag.use_tofu else TERRAFORM_SHA256SUMS_TEMPLATE,
            )
            facts.update(tool_facts)
            if tool_error:
                resolve_errors.append(tool_error)

            verification = version_tag.provider_verification
            if verification == "files":
                to_check = packages
            else:
                to_check = unverified_packages(facts, packages, platforms)

            dirhashes = {}

            if to_check:
                provider_locks, dirhashes = parse_provider_locks([
                    ctx.read(lock)
                    for lock in version_tag.provider_locks
                ])

                uncovered = verify_provider_hashes(facts, to_check, platforms, provider_locks)

                if uncovered and verification == "auto":
                    if not tool_sha256:
                        uncovered = []
                    else:
                        locked, locked_dirhashes = lock_providers(
                            ctx,
                            fetch_lock_tool(
                                ctx,
                                tool,
                                version_tag.version,
                                host_detected_os,
                                host_detected_arch,
                                TOFU_URL_TEMPLATE if version_tag.use_tofu else TERRAFORM_URL_TEMPLATE,
                                tool_sha256,
                            ),
                            uncovered,
                            platforms,
                        )
                        dirhashes = merge_provider_locks(dirhashes, locked_dirhashes)
                        uncovered = verify_provider_hashes(facts, uncovered, platforms, locked)

                enforce_lock_coverage(verification, uncovered)

            repo_mirrors[tf_repo_name] = mirror_manifest(packages)

            collected = collect_provider_dirhashes(ctx.facts, packages, dirhashes)
            for p in packages:
                key = "%s/%s/%s@%s" % (p["host"], p["namespace"], p["type"], p["version"])
                if key in collected:
                    facts[dirhash_fact_key(
                        p["host"],
                        p["namespace"],
                        p["type"],
                        p["version"],
                    )] = {"hashes": ",".join(collected[key])}

            repo_hashes[tf_repo_name] = {}
            for p in packages:
                key = "%s/%s/%s@%s" % (p["host"], p["namespace"], p["type"], p["version"])
                repo_hashes[tf_repo_name][key] = ",".join(
                    p["hashes"] + ["h1:" + h for h in collected.get(key, [])],
                )

            download = tofu_download if version_tag.use_tofu else terraform_download
            download(
                name = tf_repo_name,
                version = version_tag.version,
                os = host_detected_os,
                arch = host_detected_arch,
                tool_sha256 = tool_sha256,
                providers_json = json.encode(packages),
                resolve_errors = json.encode(resolve_errors),
            )
            if version_tag.use_tofu:
                tofu_toolchains.append(tf_repo_name)
            else:
                terraform_toolchains.append(tf_repo_name)

    tf_toolchains(
        name = "tf_toolchains",
        tflint_repos = tflint_toolchains,
        tfdoc_repos = tfdoc_toolchains,
        terraform_repos = terraform_toolchains,
        tofu_repos = tofu_toolchains,
        # string_dict, so the manifest is joined on "," (a "source@version"
        # entry never contains one).
        repo_mirrors = {k: ",".join(v) for k, v in repo_mirrors.items()},
        repo_hashes = {k: json.encode(v) for k, v in repo_hashes.items()},
        os = host_detected_os,
        arch = host_detected_arch,
    )

    return ctx.extension_metadata(reproducible = True, facts = facts)

_version_tag = tag_class(
    attrs = {
        "use_tofu": attr.bool(default = False),
        "version": attr.string(mandatory = True),
        "tflint_version": attr.string(default = TFLINT_VERSION),
        "tflint_config": attr.label(
            default = "@rules_tf//tf/toolchains/tflint:config.hcl",
            allow_single_file = True,
            cfg = "target",
        ),
        "tfdoc_version": attr.string(default = TFDOC_VERSION),
        "mirror": attr.string_list(
            mandatory = False,
            doc = "List of providers to pre-fetch into the local mirror, formatted " +
                  "as '[hostname/]namespace/type:version'. The same source may appear " +
                  "multiple times with different versions; user modules pick whichever " +
                  "version they require via their own required_providers block.",
        ),
        "provider_locks": attr.label_list(
            allow_files = True,
            doc = "`.terraform.lock.hcl` files whose zh: hashes each mirrored package must " +
                  "match. Those hashes come from `terraform providers lock`, which verifies " +
                  "the registry's SHA256SUMS signature against the keys embedded in the " +
                  "terraform binary, so they are a trust root independent of the registry. " +
                  "A lock file holds one version per provider; pass several to cover a " +
                  "multi-version mirror. Needed only to reuse lock files a repository already " +
                  "keeps: whatever they do not cover is locked by the extension itself.",
        ),
        "provider_verification": attr.string(
            default = "auto",
            values = ["auto", "files", "off"],
            doc = "Where the hashes each mirrored package is checked against come from. " +
                  "'auto' trusts the verified marks already recorded in MODULE.bazel.lock, " +
                  "checks what they leave against provider_locks, and runs `providers lock` " +
                  "for the remainder: that needs network access and any credentials the " +
                  "registry requires, runs once per version, and is answered from the " +
                  "lockfile thereafter. 'files' is a standing assertion, re-checked on " +
                  "every evaluation with recorded marks trusted not at all: every mirrored " +
                  "package must match the provider_locks files, and nothing is run. Both " +
                  "fail on an entry no hash covers. 'off' admits unverified packages on " +
                  "the registry's word, warning about each -- what a registry publishing " +
                  "no signatures leaves available. Packages a recorded mark or a " +
                  "provider_locks file covers are as verified as under 'auto', silently.",
        ),
        "mirror_json": attr.label(
            allow_single_file = True,
            doc = "A JSON file containing the provider mirror list. Alternative to " +
                  "the inline mirror attribute. The file must contain a JSON array " +
                  "of strings in the same format as the mirror attribute.",
        ),
    },
)

tf_repositories = module_extension(
    implementation = _tf_repositories,
    tag_classes = {
        "download": _version_tag,
    },
    os_dependent = True,
    arch_dependent = True,
)
