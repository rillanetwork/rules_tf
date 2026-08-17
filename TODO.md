# TODO

- Restore the signature check `tflint --init` used to make. The extension now pins each ruleset by a sha256 read from the release's `checksums.txt`, which is GitHub's word rather than a publisher's signature; `--init` verified that document against the `signing_key` the config names. Running `--init` once in the extension, at the point a fact is first minted, would give the pin and the signature both -- the shape `fetch_lock_tool` already uses for providers.
