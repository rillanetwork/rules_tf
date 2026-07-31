import json
import os
import shutil
import tempfile
import unittest

from providers_lock import (
    local_names,
    merge_into_lockfile,
    parse_lock,
    parse_manifest,
    required_providers_document,
    version_sets,
)

# What `terraform providers lock` writes, trimmed to two providers. The h1:
# entries are deliberately present: they cover the extracted directory rather
# than the package, so nothing here may pick them up.
LOCK_DOCUMENT = """\
# This file is maintained automatically by "terraform init".
# Manual edits may be lost in future updates.

provider "registry.terraform.io/hashicorp/null" {
  version     = "3.1.1"
  constraints = "3.1.1"
  hashes = [
    "h1:71sNUDvmiJcijsvfXpiLCz0lXIBSsEJjMxljt7hxMhw=",
    "zh:063466f41f1d9fd0dd93722840c1314f046d8760b1812fa67c34de0afcba5597",
    "zh:08c058e367de6debdad35fc24d97131c7cf75103baec8279aba3506a08b53faf",
  ]
}

provider "registry.terraform.io/hashicorp/random" {
  version     = "3.6.0"
  constraints = "3.6.0"
  hashes = [
    "zh:486a1c921eab5c51a480f2eb0ad85173f207c9b7bb215f3893e58bc38d3b7c75",
  ]
}
"""


class ParseLockTest(unittest.TestCase):
    def test_reads_zh_hashes_per_address_and_version(self):
        self.assertEqual(
            parse_lock(LOCK_DOCUMENT),
            {
                ("registry.terraform.io/hashicorp/null", "3.1.1"): [
                    "063466f41f1d9fd0dd93722840c1314f046d8760b1812fa67c34de0afcba5597",
                    "08c058e367de6debdad35fc24d97131c7cf75103baec8279aba3506a08b53faf",
                ],
                ("registry.terraform.io/hashicorp/random", "3.6.0"): [
                    "486a1c921eab5c51a480f2eb0ad85173f207c9b7bb215f3893e58bc38d3b7c75",
                ],
            },
        )

    def test_ignores_a_provider_with_no_zh_hashes(self):
        document = 'provider "registry.terraform.io/hashicorp/null" {\n  version = "3.1.1"\n}\n'
        self.assertEqual(parse_lock(document), {})


class ParseManifestTest(unittest.TestCase):
    def test_qualifies_unhosted_sources_and_leaves_hosted_ones(self):
        self.assertEqual(
            parse_manifest(
                ["hashicorp/random@3.6.0", "tf.example.com/acme/thing@1.0.0"],
                "registry.terraform.io",
            ),
            {
                "registry.terraform.io/hashicorp/random": {"3.6.0"},
                "tf.example.com/acme/thing": {"1.0.0"},
            },
        )

    def test_collects_every_version_of_one_source(self):
        self.assertEqual(
            parse_manifest(
                ["hashicorp/random@3.6.0", "hashicorp/random@3.1.3"],
                "registry.opentofu.org",
            ),
            {"registry.opentofu.org/hashicorp/random": {"3.6.0", "3.1.3"}},
        )

    def test_rejects_an_entry_with_no_version(self):
        with self.assertRaises(SystemExit):
            parse_manifest(["hashicorp/random"], "registry.terraform.io")


class VersionSetsTest(unittest.TestCase):
    def test_splits_a_multi_version_source_across_sets(self):
        # A dependency lock holds one version per provider, so three versions of
        # one source need three runs -- and a source with one version appears
        # only in the first.
        self.assertEqual(
            version_sets({
                "registry.terraform.io/hashicorp/random": {"3.6.0", "3.1.3", "3.3.2"},
                "registry.terraform.io/hashicorp/null": {"3.1.1"},
            }),
            [
                {
                    "registry.terraform.io/hashicorp/random": "3.1.3",
                    "registry.terraform.io/hashicorp/null": "3.1.1",
                },
                {"registry.terraform.io/hashicorp/random": "3.3.2"},
                {"registry.terraform.io/hashicorp/random": "3.6.0"},
            ],
        )

    def test_orders_prerelease_before_the_release_it_precedes(self):
        sets = version_sets({"registry.terraform.io/hashicorp/null": {"3.2.4", "3.2.4-alpha.2"}})
        self.assertEqual(
            [s["registry.terraform.io/hashicorp/null"] for s in sets],
            ["3.2.4-alpha.2", "3.2.4"],
        )


class LocalNamesTest(unittest.TestCase):
    def test_transliterates_to_what_terraform_accepts(self):
        # Letters, digits and dashes only, a letter first, no trailing dash.
        self.assertEqual(
            local_names(["registry.terraform.io/hashicorp/random"]),
            {"registry.terraform.io/hashicorp/random": "p-registry-terraform-io-hashicorp-random"},
        )

    def test_starts_with_a_letter_even_for_a_numeric_host(self):
        # terraform rejects a local name that opens with a digit, which a host
        # like an IP-addressed private registry would otherwise produce.
        for name in local_names(["10.0.0.1/acme/thing"]).values():
            self.assertRegex(name, r"^[a-z][a-z0-9-]*$")

    def test_breaks_a_collision_between_addresses_that_transliterate_alike(self):
        names = local_names(["tf.example.com/a/b", "tf-example-com/a/b"])
        self.assertEqual(len(set(names.values())), 2)

    def test_document_names_every_provider_in_the_set(self):
        document = required_providers_document({
            "registry.terraform.io/hashicorp/random": "3.6.0",
            "registry.terraform.io/hashicorp/null": "3.1.1",
        })
        required = document["terraform"]["required_providers"]
        self.assertEqual(
            sorted(entry["source"] for entry in required.values()),
            [
                "registry.terraform.io/hashicorp/null",
                "registry.terraform.io/hashicorp/random",
            ],
        )


class MergeIntoLockfileTest(unittest.TestCase):
    KEY = "@@rules_tf+//tf:extensions.bzl%tf_repositories"

    def setUp(self):
        workdir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, workdir, ignore_errors=True)
        self.path = os.path.join(workdir, "MODULE.bazel.lock")

    def lockfile(self, facts):
        path = self.path
        with open(path, "w") as handle:
            json.dump({"lockFileVersion": 26, "facts": {self.KEY: facts}}, handle)
        return path

    def facts(self, path):
        with open(path) as handle:
            return json.load(handle)["facts"][self.KEY]

    def test_records_hashes_without_disturbing_other_facts(self):
        path = self.lockfile({"package/registry.terraform.io/hashicorp/null/3.1.1/linux_amd64": {}})
        merge_into_lockfile(
            path,
            self.KEY,
            {("registry.terraform.io/hashicorp/null", "3.1.1"): ["aa", "bb"]},
            dry_run=False,
            check=False,
        )

        self.assertEqual(
            self.facts(path),
            {
                "package/registry.terraform.io/hashicorp/null/3.1.1/linux_amd64": {},
                "verified/registry.terraform.io/hashicorp/null/3.1.1": {"zh": ["aa", "bb"]},
            },
        )
        # The write is staged beside the lockfile and moved into place; nothing
        # of it may be left in the consumer's workspace.
        self.assertFalse(os.path.exists(path + ".tmp"))

    def test_leaves_another_toolchains_hashes_alone(self):
        # One target covers one toolchain; a module may declare several.
        path = self.lockfile({"verified/registry.opentofu.org/hashicorp/null/3.1.1": {"zh": ["cc"]}})
        merge_into_lockfile(
            path,
            self.KEY,
            {("registry.terraform.io/hashicorp/null", "3.1.1"): ["aa"]},
            dry_run=False,
            check=False,
        )

        self.assertIn("verified/registry.opentofu.org/hashicorp/null/3.1.1", self.facts(path))

    def test_check_fails_when_the_recorded_hashes_are_stale(self):
        path = self.lockfile({"verified/registry.terraform.io/hashicorp/null/3.1.1": {"zh": ["aa"]}})
        with self.assertRaises(SystemExit):
            merge_into_lockfile(
                path,
                self.KEY,
                {("registry.terraform.io/hashicorp/null", "3.1.1"): ["bb"]},
                dry_run=False,
                check=True,
            )

        self.assertEqual(
            self.facts(path)["verified/registry.terraform.io/hashicorp/null/3.1.1"],
            {"zh": ["aa"]},
        )

    def test_check_passes_when_they_are_current(self):
        path = self.lockfile({"verified/registry.terraform.io/hashicorp/null/3.1.1": {"zh": ["aa"]}})
        merge_into_lockfile(
            path,
            self.KEY,
            {("registry.terraform.io/hashicorp/null", "3.1.1"): ["aa"]},
            dry_run=False,
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
