import contextlib
import io
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path

from run import (
    copy_plan_json_artifact,
    module_entry,
    plan_artifact_filename,
    run_terraform_plan,
    state_dir,
)


class PlanArtifactFilenameTest(unittest.TestCase):
    def test_maps_label_with_slashes_and_colon(self):
        self.assertEqual(
            plan_artifact_filename("//terraform/dev:gateway_service"),
            "terraform--dev--gateway_service.json",
        )

    def test_maps_nested_package(self):
        self.assertEqual(
            plan_artifact_filename("//terraform/stacks/api:api-stores"),
            "terraform--stacks--api--api-stores.json",
        )


class ModuleEntryTest(unittest.TestCase):
    def test_shape(self):
        self.assertEqual(
            module_entry("//terraform/dev:gateway_service"),
            {
                "package": "terraform/dev",
                "name": "gateway_service",
                "skip": False,
                "affected": True,
            },
        )

    def test_skip_and_affected_are_constant(self):
        entry = module_entry("//terraform/dev:api")
        self.assertFalse(entry["skip"])
        self.assertTrue(entry["affected"])


class StateDirTest(unittest.TestCase):
    def test_keyed_by_root_label(self):
        self.assertEqual(state_dir("//terraform/dev:api"), "terraform/dev/api")

    def test_roots_sharing_a_package_are_distinct(self):
        self.assertNotEqual(
            state_dir("//terraform/dev:api"), state_dir("//terraform/dev:web")
        )

    def test_root_package(self):
        self.assertEqual(state_dir("//:api"), "api")


class CopyPlanJsonArtifactTest(unittest.TestCase):
    def test_copies_emitted_file_under_contract_name(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            module_dir = root / "bazel-tf" / "terraform" / "local" / "local"
            module_dir.mkdir(parents=True)
            (module_dir / "plan.tfplan.json").write_text('{"format_version":"1.2"}')
            artifacts = root / "artifacts"
            artifacts.mkdir()

            copy_plan_json_artifact(artifacts, "//terraform/local:local", root)

            out = artifacts / "terraform--local--local.json"
            self.assertEqual(json.loads(out.read_text()), {"format_version": "1.2"})

    def test_redacts_sensitive_values(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            module_dir = root / "bazel-tf" / "terraform" / "local" / "local"
            module_dir.mkdir(parents=True)
            (module_dir / "plan.tfplan.json").write_text(
                json.dumps(
                    {
                        "configuration": {
                            "root_module": {"variables": {"token": {"sensitive": True}}}
                        },
                        "variables": {"token": {"value": "hunter2"}},
                        "output_changes": {
                            "pw": {
                                "actions": ["create"],
                                "after": "hunter2",
                                "after_sensitive": True,
                            }
                        },
                    }
                )
            )
            artifacts = root / "artifacts"
            artifacts.mkdir()

            copy_plan_json_artifact(artifacts, "//terraform/local:local", root)

            out = (artifacts / "terraform--local--local.json").read_text()
            self.assertNotIn("hunter2", out)

    def test_unparseable_emitted_file_warns_and_skips(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            module_dir = root / "bazel-tf" / "terraform" / "local" / "local"
            module_dir.mkdir(parents=True)
            (module_dir / "plan.tfplan.json").write_text('{"secret": "hunter2"')
            artifacts = root / "artifacts"
            artifacts.mkdir()
            stderr = io.StringIO()

            with contextlib.redirect_stderr(stderr):
                copy_plan_json_artifact(artifacts, "//terraform/local:local", root)

            self.assertFalse((artifacts / "terraform--local--local.json").exists())
            self.assertIn("[WARN]", stderr.getvalue())

    def test_missing_emitted_file_warns_and_skips(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            stderr = io.StringIO()

            with contextlib.redirect_stderr(stderr):
                copy_plan_json_artifact(artifacts, "//terraform/local:local", root)

            self.assertFalse((artifacts / "terraform--local--local.json").exists())
            self.assertIn("[WARN]", stderr.getvalue())


class RunTerraformPlanTest(unittest.TestCase):
    def plan_env(self, plan_json):
        with mock.patch("run.subprocess.run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = ""
            run_terraform_plan("//terraform/dev:api", Path("/ws"), None, plan_json)
        return run.call_args.kwargs["env"]

    def test_requests_plan_json_from_the_plan_step(self):
        self.assertEqual(self.plan_env(True)["RULES_TF_PLAN_JSON"], "1")

    def test_inherits_the_environment_otherwise(self):
        self.assertIsNone(self.plan_env(False))


if __name__ == "__main__":
    unittest.main()
