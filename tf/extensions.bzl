load(
    "@rules_tf//tf/toolchains/terraform:toolchain.bzl",
    "terraform_download",
    TERRAFORM_SHA256SUMS_TEMPLATE = "SHA256SUMS_TEMPLATE",
    TERRAFORM_URL_TEMPLATE = "URL_TEMPLATE",
)
load("@rules_tf//tf/toolchains/tflint:toolchain.bzl", "tflint_download")
load("@rules_tf//tf/toolchains/tfdoc:toolchain.bzl", "tfdoc_download")
load(
    "@rules_tf//tf/toolchains/tofu:toolchain.bzl",
    "tofu_download",
    TOFU_SHA256SUMS_TEMPLATE = "SHA256SUMS_TEMPLATE",
    TOFU_URL_TEMPLATE = "URL_TEMPLATE",
)
load("@rules_tf//tf:toolchains.bzl", "tf_toolchains")
load(
    "@rules_tf//tf/toolchains:utils.bzl",
    "DEFAULT_REGISTRY",
    "MIRROR_PLATFORMS",
    "fetch_lock_tool",
    "lock_providers",
    "merge_provider_locks",
    "mirror_manifest",
    "parse_mirror_entries",
    "parse_provider_locks",
    "resolve_providers",
    "resolve_tool_sha256",
    "unverified_packages",
    "verify_provider_hashes",
)
load("@rules_tf//tf:versions.bzl", "TFDOC_VERSION")
load("@rules_tf//tf:versions.bzl", "TFLINT_VERSION")

def detect_host_platform(ctx):
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

    # Coordinates are resolved for every platform a toolchain runs on, plus the
    # host when it is something else again.
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

    # Accumulated across every download tag and handed back at the end, for
    # bzlmod to persist in MODULE.bazel.lock.
    facts = {}

    for module in ctx.modules:
        for index, version_tag in enumerate(module.tags.download):
            tf_repo_name = _repo_name(
                module=module,
                tool = "tf",
                index = index,
                suffix = "_{}_{}".format(host_detected_os, host_detected_arch),
            )
            tfdoc_repo_name = _repo_name(
                module=module,
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
            tfdoc_toolchains += [tfdoc_repo_name]

            tflint_repo_name = _repo_name(
                module=module,
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

            tflint_toolchains += [tflint_repo_name]

            if version_tag.mirror_json:
                mirror = json.decode(ctx.read(version_tag.mirror_json))
            else:
                mirror = version_tag.mirror

            if mirror == None:
                fail("module {} is missing both mirror and mirror_json attributes; one must be set".format(module.name))

            # The coordinates below reach the repo rule as attributes;
            # everything learned from the registry comes back as facts, which
            # are what the lockfile records.
            packages, tag_facts, resolve_errors = resolve_providers(
                ctx,
                parse_mirror_entries(mirror),
                DEFAULT_REGISTRY[version_tag.use_tofu],
                host_detected_os,
                host_detected_arch,
                ctx.facts,
            )
            facts.update(tag_facts)

            # Resolved here rather than in the download repository so that every
            # byte that repository fetches is pinned by an attribute, which is
            # what lets it be served from the repo contents cache. The same
            # hash pins the binary the verification below runs.
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

            # Every package hash is known before a byte is fetched, so the
            # signature-derived check runs here, against hashes a publisher
            # signed. A package whose recorded coordinates already carry the
            # check is left alone, which is what keeps a second evaluation off
            # the network.
            # A tool release that could not be resolved has recorded its error
            # already, and the mirror cannot be built without it, so locking is
            # left to an evaluation that can reach the release rather than
            # failing here.
            pending = unverified_packages(facts, packages, platforms)
            if pending and (tool_sha256 or version_tag.provider_verification != "auto"):
                provider_locks = parse_provider_locks([
                    ctx.read(lock)
                    for lock in version_tag.provider_locks
                ])

                if version_tag.provider_verification == "auto":
                    # Fetched only when something is left to verify, and only
                    # for the host: the tool is here to check signatures, not to
                    # be built with.
                    provider_locks = merge_provider_locks(provider_locks, lock_providers(
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
                        pending,
                    ))

                verify_provider_hashes(
                    facts,
                    pending,
                    platforms,
                    provider_locks,
                    version_tag.provider_verification != "off",
                )

            repo_mirrors[tf_repo_name] = mirror_manifest(packages)

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
                tofu_toolchains += [tf_repo_name]
            else:
                terraform_toolchains += [tf_repo_name]

    tf_toolchains(
        name = "tf_toolchains",
        tflint_repos = tflint_toolchains,
        tfdoc_repos = tfdoc_toolchains,
        terraform_repos = terraform_toolchains,
        tofu_repos = tofu_toolchains,
        # string_dict, so the manifest is joined on "," (a "source@version"
        # entry never contains one).
        repo_mirrors = {k: ",".join(v) for k, v in repo_mirrors.items()},
        os = host_detected_os,
        arch = host_detected_arch,
    )

    # reproducible: every network answer this extension depends on is now held
    # in `facts`, so a second evaluation with the same manifest defines exactly
    # the same repos without asking the registry anything. That keeps the
    # extension out of the lockfile's moduleExtensions section; the facts it
    # returns are persisted separately.
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
                  "'auto' runs `providers lock` for any version whose hash is not already " +
                  "recorded in MODULE.bazel.lock or covered by provider_locks: that needs " +
                  "network access and any credentials the registry requires, runs once per " +
                  "version, and is answered from the lockfile thereafter. 'files' uses " +
                  "provider_locks alone and runs nothing. Both fail on an entry no hash " +
                  "covers. 'off' admits packages on the registry's word, warning about each, " +
                  "which is what a registry publishing no signatures leaves available.",
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
