# TODO

- Make the release process update the version in the README's Getting Started snippet. It hardcodes `bazel_dep(name = "rules_tf", version = "1.0.0")` (README.md:27), so every release leaves it stale: it still says 1.0.0 after v2.0.0. Either bump it in a pre-tag step, or have the release workflow rewrite and commit it.
- Fix the broken ordered-list numbering under "Using Tf Modules" (README.md:224, 249, 280, 319). Every item is written as `1.` and each is followed by a fenced code block starting at column 0, which closes the list, so GitHub renders four separate lists all numbered "1." rather than 1-4. Indent the code blocks to the list content column to keep them inside their items, or drop the list and use headings.
