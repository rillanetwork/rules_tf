"""Unit tests for the generated backend configuration.

These run at analysis time and reach no backend: only the rendering of the
`terraform { backend }` block into Terraform's JSON syntax is covered.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":defs.bzl", "backend_content")

def _backend_content_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        """{
	"terraform": {
		"backend": {
			"local": {
				"path": "terraform.tfstate"
			}
		}
	}
}
""",
        backend_content("local", json.encode({"path": "terraform.tfstate"})),
    )

    # A backend with no settings at all still needs its labelled block, or
    # Terraform falls back to the implicit local backend.
    asserts.equals(
        env,
        """{
	"terraform": {
		"backend": {
			"local": {}
		}
	}
}
""",
        backend_content("local", "{}"),
    )

    return unittest.end(env)

def _backend_types_test_impl(ctx):
    env = unittest.begin(ctx)

    # Terraform's JSON syntax carries a backend setting's real type, and writes
    # a nested block as a nested object.
    content = backend_content("s3", json.encode({
        "bucket": "example-bucket",
        "max_retries": 7,
        "skip_region_validation": True,
        "assume_role": {"role_arn": "arn:aws:iam::123456789012:role/tf"},
    }))
    backend = json.decode(content)["terraform"]["backend"]["s3"]

    asserts.equals(env, "example-bucket", backend["bucket"])
    asserts.equals(env, 7, backend["max_retries"])
    asserts.equals(env, True, backend["skip_region_validation"])
    asserts.equals(env, {"role_arn": "arn:aws:iam::123456789012:role/tf"}, backend["assume_role"])

    return unittest.end(env)

def _backend_quoting_test_impl(ctx):
    env = unittest.begin(ctx)

    # A quote, a backslash, or a `${...}` sequence reaches Terraform verbatim:
    # JSON escapes it, and Terraform does not interpolate inside a JSON string
    # that is not a template.
    value = 'a "quoted" ${interpolation} and a \\ backslash'
    content = backend_content("local", json.encode({"path": value}))

    asserts.equals(env, value, json.decode(content)["terraform"]["backend"]["local"]["path"])

    return unittest.end(env)

_backend_content_test = unittest.make(_backend_content_test_impl)
_backend_types_test = unittest.make(_backend_types_test_impl)
_backend_quoting_test = unittest.make(_backend_quoting_test_impl)

def defs_test_suite():
    """Registers the backend rendering tests."""
    unittest.suite(
        "backend_tests",
        _backend_content_test,
        _backend_types_test,
        _backend_quoting_test,
    )
