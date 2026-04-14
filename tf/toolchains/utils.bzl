def get_sha256sum(shasums, file):
    lines = shasums.splitlines()
    for line in lines:
        if not line.endswith(file):
            continue
        return line.split(" ")[0].strip()

    return None

def parse_mirror_entries(mirror):
    """Parses a list of "[hostname/]namespace/type:version" strings.

    Returns a list of {"source": ..., "version": ...} dicts, deduplicated on
    (source, version). Fails on malformed entries or duplicates.
    """
    seen = {}
    parsed = []
    for entry in mirror:
        elems = entry.split(":")
        if len(elems) != 2 or elems[0] == "" or elems[1] == "":
            fail("mirror entry must be of the form '[hostname/]namespace/type:version', was: %s" % entry)

        source = elems[0]
        version = elems[1]

        source_elems = source.split("/")
        if len(source_elems) < 2 or len(source_elems) > 3:
            fail("mirror entry source must be '[hostname/]namespace/type', was: %s" % source)

        version_elems = version.split(".")
        if len(version_elems) != 3:
            fail("mirror entry version must be 'x.y.z', was: %s (in %s)" % (version, entry))

        key = "%s@%s" % (source, version)
        if key in seen:
            fail("duplicate mirror entry: %s" % entry)
        seen[key] = True
        parsed.append({"source": source, "version": version})

    return parsed

def render_mirror_versions_tf_jsons(parsed_entries):
    """Returns one versions.tf.json dict per (source, version) pair.

    Terraform treats multiple required_providers entries for the same source as
    a combined constraint (logical AND), so fetching multiple versions of one
    source in a single `terraform providers mirror` invocation is not possible.
    Instead, callers iterate over the returned list, writing each dict as
    versions.tf.json and running `terraform providers mirror` once per entry
    into the same output directory.  The on-disk mirror layout separates by
    version, so the results accumulate correctly.
    """
    result = []
    for entry in parsed_entries:
        result.append({
            "terraform": [
                {"required_providers": [{"p": {"source": entry["source"], "version": entry["version"]}}]},
            ],
        })
    return result

def mirror_manifest(parsed_entries):
    """Returns the canonical "source@version" strings used as the toolchain manifest."""
    return ["%s@%s" % (e["source"], e["version"]) for e in parsed_entries]
