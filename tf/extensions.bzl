load("@rules_tf//tf/toolchains/terraform:toolchain.bzl", "terraform_download")
load("@rules_tf//tf/toolchains/tflint:toolchain.bzl", "tflint_download")
load("@rules_tf//tf/toolchains/tfdoc:toolchain.bzl", "tfdoc_download")
load("@rules_tf//tf/toolchains/tofu:toolchain.bzl", "tofu_download")
load("@rules_tf//tf:toolchains.bzl", "tf_toolchains")
load(
    "@rules_tf//tf/toolchains:utils.bzl",
    "mirror_manifest",
    "parse_mirror_entries",
    "parse_provider_locks",
    "resolve_providers",
    "verify_against_provider_locks",
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

_DEFAULT_REGISTRY = {
    True: "registry.opentofu.org",
    False: "registry.terraform.io",
}

def _tf_repositories(ctx):
    host_detected_os, host_detected_arch = detect_host_platform(ctx)

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
                index = 0,
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
                index = 0,
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

            # The concrete coordinates below become repo attributes, which
            # the lockfile records verbatim in generatedRepoSpecs, and
            # everything learned from the registry comes back as facts, which
            # the lockfile persists.
            packages, tag_facts = resolve_providers(
                ctx,
                parse_mirror_entries(mirror),
                _DEFAULT_REGISTRY[version_tag.use_tofu],
                host_detected_os,
                host_detected_arch,
                ctx.facts,
            )
            facts.update(tag_facts)

            # Every package hash is known before a byte is fetched, so the
            # signature-derived check runs here too.
            provider_locks = parse_provider_locks([
                ctx.read(lock)
                for lock in version_tag.provider_locks
            ])
            if len(provider_locks) > 0:
                verify_against_provider_locks(
                    packages,
                    provider_locks,
                    version_tag.provider_locks_strict,
                )

            repo_mirrors[tf_repo_name] = mirror_manifest(packages)

            download = tofu_download if version_tag.use_tofu else terraform_download
            download(
                name = tf_repo_name,
                version = version_tag.version,
                os = host_detected_os,
                arch = host_detected_arch,
                providers_json = json.encode(packages),
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
                  "multi-version mirror.",
        ),
        "provider_locks_strict": attr.bool(
            default = False,
            doc = "Fail rather than warn when a mirror entry has no dependency-lock entry.",
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
