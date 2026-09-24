# TODO

- Make the release process update the version in the README's Getting Started snippet. It hardcodes `bazel_dep(name = "rules_tf", version = "1.0.0")` (README.md:27), so every release leaves it stale: it still says 1.0.0 after v2.0.0. Either bump it in a pre-tag step, or have the release workflow rewrite and commit it.
