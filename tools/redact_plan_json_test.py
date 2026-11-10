"""Tests for redact_plan_json: sensitive values must not survive redaction of a plan."""

import copy
import json
import os
import unittest
from pathlib import Path

from redact_plan_json import REDACTED, redact_masked, redact_plan

FIXTURE = Path(os.path.dirname(__file__)) / "testdata" / "sensitive_plan" / "plan.json"


def load_fixture() -> dict:
    return json.loads(FIXTURE.read_text())


def strings(value) -> list[str]:
    if isinstance(value, dict):
        return [s for v in value.values() for s in strings(v)]
    if isinstance(value, list):
        return [s for v in value for s in strings(v)]
    return [value] if isinstance(value, str) else []


class RedactMaskedTest(unittest.TestCase):
    def test_whole_value_sensitive(self):
        self.assertEqual(redact_masked({"a": 1}, True), REDACTED)

    def test_nested_object_and_list(self):
        self.assertEqual(
            redact_masked(
                {"a": "keep", "b": "hide", "c": ["keep", "hide"]},
                {"b": True, "c": [False, True]},
            ),
            {"a": "keep", "b": REDACTED, "c": ["keep", REDACTED]},
        )

    def test_mask_shorter_than_list(self):
        self.assertEqual(redact_masked(["a", "b"], []), ["a", "b"])

    def test_no_mask(self):
        self.assertEqual(redact_masked({"a": "keep"}, None), {"a": "keep"})
        self.assertEqual(redact_masked({"a": "keep"}, False), {"a": "keep"})

    def test_null_stays_null(self):
        self.assertIsNone(redact_masked(None, True))


class RedactPlanFixtureTest(unittest.TestCase):
    def setUp(self):
        self.original = load_fixture()
        self.password = self.original["prior_state"]["values"]["outputs"]["pw"]["value"]
        self.redacted = redact_plan(copy.deepcopy(self.original))

    def test_fixture_holds_secrets_before_redaction(self):
        found = strings(self.original)
        for secret in (
            "SECRET-ONE",
            "SECRET-TWO",
            "DEFAULT-SECRET-VALUE",
            self.password,
        ):
            self.assertIn(secret, found)

    def test_no_secret_survives(self):
        for s in strings(self.redacted):
            for secret in (
                "SECRET-ONE",
                "SECRET-TWO",
                "DEFAULT-SECRET-VALUE",
                self.password,
            ):
                self.assertNotIn(secret, s)

    def test_only_sensitive_variable_values_redacted(self):
        variables = self.redacted["variables"]
        self.assertEqual(variables["secret"]["value"], REDACTED)
        self.assertEqual(variables["secret_with_default"]["value"], REDACTED)
        self.assertEqual(variables["plain"]["value"], "two")

    def test_non_sensitive_values_kept(self):
        mixed = next(
            rc
            for rc in self.redacted["resource_changes"]
            if rc["address"] == "terraform_data.mixed"
        )
        self.assertEqual(mixed["change"]["before"]["input"]["name"], "one")
        self.assertEqual(mixed["change"]["after"]["input"]["name"], "two")
        self.assertEqual(mixed["change"]["after"]["input"]["token"], REDACTED)
        self.assertEqual(self.redacted["output_changes"]["plain"]["after"], "two")

    def test_report_fields_unchanged(self):
        def summary(plan):
            return [
                (rc["address"], rc.get("action_reason"), rc["change"]["actions"])
                for rc in plan["resource_changes"]
            ]

        self.assertEqual(summary(self.redacted), summary(self.original))

    def test_resource_drift_redacted(self):
        plan = load_fixture()
        plan["resource_drift"] = copy.deepcopy(plan["resource_changes"])
        for s in strings(redact_plan(plan)["resource_drift"]):
            self.assertNotIn("SECRET-ONE", s)
            self.assertNotIn(self.password, s)

    def test_deferred_changes_redacted(self):
        plan = load_fixture()
        plan["deferred_changes"] = [
            {"reason": "provider_config_unknown", "resource_change": rc}
            for rc in copy.deepcopy(plan["resource_changes"])
        ]
        for s in strings(redact_plan(plan)["deferred_changes"]):
            self.assertNotIn("SECRET-ONE", s)
            self.assertNotIn(self.password, s)

    def test_error_envelope_passes_through(self):
        self.assertEqual(redact_plan({"error": "boom"}), {"error": "boom"})


def interpolation_plan(secret: str) -> dict:
    """Builds a plan whose sensitive variable `secret` is embedded inside an unmasked
    JSON string."""
    blob = json.dumps(
        [{"name": "api", "environment": [{"name": "TOKEN", "value": secret}]}]
    )
    return {
        "configuration": {
            "root_module": {"variables": {"token": {"sensitive": True}, "stage": {}}}
        },
        "variables": {"token": {"value": secret}, "stage": {"value": "dev"}},
        "resource_changes": [
            {
                "address": "aws_ecs_task_definition.api",
                "change": {
                    "actions": ["update"],
                    "before": {"container_definitions": blob, "family": "dev"},
                    "after": {"container_definitions": blob, "family": "dev"},
                    "before_sensitive": {},
                    "after_sensitive": {},
                },
            }
        ],
    }


class RedactPlanScrubTest(unittest.TestCase):
    def test_secret_inside_unmasked_string(self):
        plan = redact_plan(interpolation_plan('s3cr3t"token'))
        after = plan["resource_changes"][0]["change"]["after"]
        self.assertNotIn("s3cr3t", json.dumps(plan))
        self.assertIn(REDACTED, after["container_definitions"])
        self.assertIn('"name": "api"', after["container_definitions"])

    def test_non_sensitive_variable_values_not_scrubbed(self):
        plan = redact_plan(interpolation_plan("s3cr3t-token"))
        after = plan["resource_changes"][0]["change"]["after"]
        self.assertEqual(after["family"], "dev")
        self.assertEqual(plan["variables"]["stage"]["value"], "dev")

    def test_short_secret_only_replaced_whole(self):
        plan = interpolation_plan("abc")
        plan["resource_changes"][0]["change"]["after"]["exact"] = "abc"
        plan["resource_changes"][0]["change"]["after"]["family"] = "abcdef"
        after = redact_plan(plan)["resource_changes"][0]["change"]["after"]
        self.assertEqual(after["exact"], REDACTED)
        self.assertEqual(after["family"], "abcdef")


if __name__ == "__main__":
    unittest.main()


class JsonEncodedSecretTest(unittest.TestCase):
    # Terraform is written in Go, whose JSON encoder escapes <, >, & and U+2028,
    # so a secret can appear in a plan in that form.
    SECRET = 'pw<b>&c"d é\u2028'
    GO_ENCODED = '{"v":"pw\\u003cb\\u003e\\u0026c\\"d é\\u2028"}'

    def test_go_escaped_secret_scrubbed(self):
        plan = interpolation_plan(self.SECRET)
        after = plan["resource_changes"][0]["change"]["after"]
        after["container_definitions"] = self.GO_ENCODED
        after = redact_plan(plan)["resource_changes"][0]["change"]["after"]
        self.assertEqual(after["container_definitions"], '{"v":"' + REDACTED + '"}')

    def test_secret_in_map_key_scrubbed(self):
        plan = interpolation_plan("s3cr3t-token")
        after = plan["resource_changes"][0]["change"]["after"]
        after["tags"] = {"key-s3cr3t-token": "v"}
        after = redact_plan(plan)["resource_changes"][0]["change"]["after"]
        self.assertEqual(after["tags"], {"key-" + REDACTED: "v"})
