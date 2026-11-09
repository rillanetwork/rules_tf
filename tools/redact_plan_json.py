"""Redacts sensitive values from a Terraform/OpenTofu plan JSON, including copies in
unmasked fields."""

import json
import sys
from typing import Any

REDACTED = "(sensitive value)"

# Secrets shorter than this are only redacted on exact match, never as substrings, to
# avoid mangling unrelated text.
MIN_SUBSTRING_LENGTH = 8

# Characters Go's encoding/json escapes by default, unlike Python's json.dumps.
_GO_JSON_ESCAPES = {
    "<": "\\u003c",
    ">": "\\u003e",
    "&": "\\u0026",
    "\u2028": "\\u2028",
    "\u2029": "\\u2029",
}


def _json_escaped_forms(secret: str) -> set[str]:
    """Returns the forms a secret takes inside a JSON string, as written by Python and
    by Go."""
    go = json.dumps(secret, ensure_ascii=False)[1:-1]
    for char, escape in _GO_JSON_ESCAPES.items():
        go = go.replace(char, escape)
    return {json.dumps(secret)[1:-1], go}


def _leaf_strings(value: Any) -> list[str]:
    if isinstance(value, dict):
        return [s for v in value.values() for s in _leaf_strings(v)]
    if isinstance(value, list):
        return [s for v in value for s in _leaf_strings(v)]
    return [value] if isinstance(value, str) else []


class _Redactor:
    def __init__(self) -> None:
        self.secrets: set[str] = set()

    def redact(self, value: Any) -> str:
        """Records every string in value as a secret and returns the redaction
        placeholder."""
        self.secrets.update(s for s in _leaf_strings(value) if s != REDACTED)
        return REDACTED

    def masked(self, value: Any, mask: Any) -> Any:
        """Redacts the parts of value that mask marks True, recording them as secrets.

        Args:
            value: The plan value to redact.
            mask: A Terraform *_sensitive structure mirroring value, or None.
        """
        if value is None:
            return None
        if mask is True:
            return self.redact(value)
        if isinstance(value, dict) and isinstance(mask, dict):
            return {k: self.masked(v, mask.get(k)) for k, v in value.items()}
        if isinstance(value, list) and isinstance(mask, list):
            return [
                self.masked(v, mask[i] if i < len(mask) else None)
                for i, v in enumerate(value)
            ]
        return value

    def change(self, change: dict) -> None:
        for side in ("before", "after"):
            if side in change:
                change[side] = self.masked(
                    change[side], change.get(f"{side}_sensitive")
                )

    def resource_changes(self, resource_changes: list) -> None:
        for rc in resource_changes:
            if isinstance(rc.get("change"), dict):
                self.change(rc["change"])

    def outputs(self, outputs: dict) -> None:
        for output in outputs.values():
            if output.get("sensitive") and "value" in output:
                output["value"] = self.redact(output["value"])

    def values_module(self, module: dict) -> None:
        """Redacts sensitive resource values in a values module and its child
        modules."""
        for resource in module.get("resources", []):
            if "values" in resource:
                resource["values"] = self.masked(
                    resource["values"], resource.get("sensitive_values")
                )
        for child in module.get("child_modules", []):
            self.values_module(child)

    def values(self, values: dict) -> None:
        self.outputs(values.get("outputs", {}))
        if isinstance(values.get("root_module"), dict):
            self.values_module(values["root_module"])

    def config_module(self, module: dict) -> None:
        """Redacts defaults of sensitive variables in a configuration module and its
        called modules."""
        for variable in module.get("variables", {}).values():
            if variable.get("sensitive") and "default" in variable:
                variable["default"] = self.redact(variable["default"])
        for call in module.get("module_calls", {}).values():
            if isinstance(call.get("module"), dict):
                self.config_module(call["module"])

    def scrub(self, value: Any) -> Any:
        """Replaces every recorded secret found in any string or key of value.

        Call prepare_scrub() first.
        """
        if isinstance(value, dict):
            return {self._scrub_str(k): self.scrub(v) for k, v in value.items()}
        if isinstance(value, list):
            return [self.scrub(v) for v in value]
        if not isinstance(value, str):
            return value
        return self._scrub_str(value)

    def _scrub_str(self, value: str) -> str:
        if value == REDACTED:
            return value
        if value in self.secrets:
            return REDACTED
        for secret in self._substring_secrets:
            value = value.replace(secret, REDACTED)
        return value

    def prepare_scrub(self) -> None:
        forms = set()
        for secret in self.secrets:
            if len(secret) >= MIN_SUBSTRING_LENGTH:
                forms.add(secret)
                forms.update(_json_escaped_forms(secret))
        # Longest first, so a secret containing another is replaced whole.
        self._substring_secrets = sorted(forms, key=len, reverse=True)


def redact_masked(value: Any, mask: Any) -> Any:
    """Redacts value wherever mask marks it sensitive.

    Args:
        value: The value to redact.
        mask: A Terraform *_sensitive structure mirroring value.

    Returns:
        The redacted copy of value.
    """
    return _Redactor().masked(value, mask)


def redact_plan(plan: dict) -> dict:
    """Redacts a plan JSON in place and returns it.

    Sensitive values are replaced, then every other occurrence of those values
    anywhere in the plan is scrubbed too.
    """
    r = _Redactor()

    configuration = plan.get("configuration")
    root_config = (
        configuration.get("root_module") if isinstance(configuration, dict) else None
    )
    root_variables = (
        root_config.get("variables", {}) if isinstance(root_config, dict) else {}
    )
    for name, variable in plan.get("variables", {}).items():
        if "value" not in variable:
            continue
        if root_variables.get(name, {}).get("sensitive"):
            variable["value"] = r.redact(variable["value"])
    if isinstance(root_config, dict):
        r.config_module(root_config)

    r.resource_changes(plan.get("resource_changes", []))
    r.resource_changes(plan.get("resource_drift", []))
    for deferred in plan.get("deferred_changes", []):
        if isinstance(deferred.get("resource_change"), dict):
            r.resource_changes([deferred["resource_change"]])

    for change in plan.get("output_changes", {}).values():
        r.change(change)

    if isinstance(plan.get("planned_values"), dict):
        r.values(plan["planned_values"])
    prior_state = plan.get("prior_state")
    if isinstance(prior_state, dict) and isinstance(prior_state.get("values"), dict):
        r.values(prior_state["values"])

    r.prepare_scrub()
    scrubbed = r.scrub(plan)
    plan.clear()
    plan.update(scrubbed)
    return plan


def main(argv: list[str]) -> int:
    if not 2 <= len(argv) <= 3:
        print(f"usage: {argv[0]} IN [OUT]", file=sys.stderr)
        return 2

    src = argv[1]
    dst = argv[2] if len(argv) == 3 else "-"
    if src == "-":
        plan = json.load(sys.stdin)
    else:
        with open(src) as f:
            plan = json.load(f)

    redacted = json.dumps(redact_plan(plan))
    if dst == "-":
        sys.stdout.write(redacted)
    else:
        with open(dst, "w") as f:
            f.write(redacted)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
