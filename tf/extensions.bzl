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
load(
    "@rules_tf//tf/toolchains/tfdoc:toolchain.bzl",
    "tfdoc_download",
    TFDOC_ARCHIVE_TEMPLATE = "ARCHIVE_TEMPLATE",
    TFDOC_SHA256SUMS_TEMPLATE = "SHA256SUMS_TEMPLATE",
)
load(
    "@rules_tf//tf/toolchains/tflint:plugins.bzl",
    "parse_tflint_plugins",
    "resolve_tflint_plugins",
    "unverified_plugins",
    "verify_tflint_plugins",
    "warn_unverified_plugins",
)
load(
    "@rules_tf//tf/toolchains/tflint:toolchain.bzl",
    "tflint_download",
    TFLINT_ARCHIVE_TEMPLATE = "ARCHIVE_TEMPLATE",
    TFLINT_SHA256SUMS_TEMPLATE = "SHA256SUMS_TEMPLATE",
    TFLINT_URL_TEMPLATE = "URL_TEMPLATE",
)
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

            # Resolved here rather than in the download repository for the
            # reason the tf tool archive is: every byte that repository fetches
            # is then pinned by an attribute, which is what lets it declare
            # itself reproducible and be served from the repo contents cache.
            tfdoc_sha256, tfdoc_facts, tfdoc_error = resolve_tool_sha256(
                ctx,
                "terraform-docs",
                version_tag.tfdoc_version,
                host_detected_os,
                host_detected_arch,
                ctx.facts,
                TFDOC_SHA256SUMS_TEMPLATE,
                archive_template = TFDOC_ARCHIVE_TEMPLATE,
            )
            facts.update(tfdoc_facts)

            tfdoc_download(
                name = tfdoc_repo_name,
                version = version_tag.tfdoc_version,
                os = host_detected_os,
                arch = host_detected_arch,
                tool_sha256 = tfdoc_sha256,
                resolve_errors = json.encode([tfdoc_error] if tfdoc_error else []),
            )
            tfdoc_toolchains.append(tfdoc_repo_name)

            tflint_repo_name = _repo_name(
                module = module,
                tool = "tflint",
                index = index,
                suffix = "_{}_{}".format(host_detected_os, host_detected_arch),
            )

            tflint_sha256, tflint_facts, tflint_error = resolve_tool_sha256(
                ctx,
                "tflint",
                version_tag.tflint_version,
                host_detected_os,
                host_detected_arch,
                ctx.facts,
                TFLINT_SHA256SUMS_TEMPLATE,
                archive_template = TFLINT_ARCHIVE_TEMPLATE,
            )
            facts.update(tflint_facts)
            tflint_errors = [tflint_error] if tflint_error else []

            # The config is read here as well as templated into the download
            # repository: the rulesets it declares are what the extension has to
            # resolve, and only what it resolves ends up in the lockfile.
            tflint_config = ctx.read(version_tag.tflint_config)
            tflint_plugins, plugin_facts, plugin_errors = resolve_tflint_plugins(
                ctx,
                parse_tflint_plugins(tflint_config),
                host_detected_os,
                host_detected_arch,
                ctx.facts,
            )
            facts.update(plugin_facts)
            tflint_errors.extend(plugin_errors)

            # Every ruleset hash is known before a byte is fetched, so the
            # signature check runs here, against the release tflint
            # authenticates. A recorded mark settles it: that keeps a second
            # evaluation off the network, and it self-heals a lockfile written
            # before the check existed, which carries no mark and so verifies
            # once more.
            pending_plugins = unverified_plugins(facts, tflint_plugins, platforms)
            if pending_plugins:
                if version_tag.tflint_plugin_verification == "off":
                    warn_unverified_plugins(pending_plugins)
                elif not tflint_sha256:
                    # A tflint release that could not be resolved has recorded
                    # its error already, and nothing can lint without it, so
                    # the check is left to an evaluation that can reach the
                    # release.
                    pass
                else:
                    # Fetched only when something is left to verify, and only
                    # for the host: this copy of tflint is here to check
                    # signatures, not to lint with.
                    tflint_errors.extend(verify_tflint_plugins(
                        ctx,
                        fetch_lock_tool(
                            ctx,
                            "tflint",
                            version_tag.tflint_version,
                            host_detected_os,
                            host_detected_arch,
                            TFLINT_URL_TEMPLATE,
                            tflint_sha256,
                            archive_template = TFLINT_ARCHIVE_TEMPLATE,
                        ),
                        tflint_config,
                        pending_plugins,
                        facts,
                        platforms,
                        "tflint_verify/%s" % tflint_repo_name,
                    ))

            tflint_download(
                name = tflint_repo_name,
                version = version_tag.tflint_version,
                os = host_detected_os,
                arch = host_detected_arch,
                tool_sha256 = tflint_sha256,
                config = version_tag.tflint_config,
                plugins_json = json.encode(tflint_plugins),
                resolve_errors = json.encode(tflint_errors),
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
        "tflint_plugin_verification": attr.string(
            default = "auto",
            values = ["auto", "off"],
            doc = "Whether each mirrored tflint ruleset must match a release whose signature " +
                  "was verified. 'auto' trusts the verified marks already recorded in " +
                  "MODULE.bazel.lock and runs `tflint --init` for what they leave: that needs " +
                  "network access, runs once per release, and is answered from the lockfile " +
                  "thereafter. It fails for a ruleset tflint cannot check -- one outside " +
                  "terraform-linters whose plugin block carries no signing_key. 'off' admits " +
                  "rulesets on the release host's word, warning about each, which is what a " +
                  "config with no key to hand leaves available. Rulesets a recorded mark " +
                  "covers are as verified as under 'auto', silently.",
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
