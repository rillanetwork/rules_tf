# Tool release signatures

Every tool this ruleset downloads - terraform, tofu, tflint, terraform-docs - is
pinned by a sha256 read out of a checksum document published alongside the
release. That pin is what makes each download repository reproducible, but on
its own it is only as trustworthy as the document, which arrives over HTTPS and
is otherwise the release host's word.

Where the publisher signs that document, the signature is checked before any
hash is read out of it, and the resulting facts in `MODULE.bazel.lock` carry a
`verified` mark.

## What each publisher actually signs

The four tools do not sign the same way, and two of them do not sign at all:

| tool | detached OpenPGP signature | checked here |
| --- | --- | --- |
| terraform | `terraform_<version>_SHA256SUMS.sig`, RSA over SHA-256 | yes |
| tofu | `tofu_<version>_SHA256SUMS.gpgsig`, RSA over SHA-512 | yes |
| tflint | none - `checksums.txt` is signed with cosign keyless | no |
| terraform-docs | none published at all | no |

OpenTofu also publishes a `SHA256SUMS.sig` and a `SHA256SUMS.pem` next to the
`.gpgsig`. Those two are a cosign keyless bundle rather than an alternative
OpenPGP signature, so the `.gpgsig` is the file to check and the one this reads.

terraform's releases additionally carry a `SHA256SUMS.72D7468F.sig`, which is
the same signature named by the primary key's id. Every terraform release
checked, from 0.12.31 to 1.13.3, is signed by the subkey
`374EC75B485913604A831CC7C820C6D5CD27AB87` rather than by the primary key.

## Choosing what is checked

```starlark
tf.version(
    version = "1.9.5",
    tool_verification = "auto",  # the default
)
```

`auto` trusts the `verified` marks already recorded in `MODULE.bazel.lock`, and
fetches and checks a signature for whatever they leave. That needs network
access, runs once per release, and is answered from the lockfile thereafter. A
document whose signature does not verify fails the build, and no hash is
recorded from it - a fact minted from an unverified document would be believed
by every later evaluation.

`off` admits every release on the release host's word without fetching a
signature at all. Releases that a recorded mark already covers stay as verified
as they were under `auto`, silently.

Under either setting, tflint and terraform-docs warn once, when their hashes are
first resolved. No setting makes them verify, because neither publishes anything
to verify against.

## Where a lockfile written before this existed lands

A `tool/` fact with no `verified` key reads as unverified, so the first
evaluation after upgrading re-fetches the checksum document, checks its
signature, and rewrites the fact with the mark. The sha256 does not change - it
was already the publisher's - so the lockfile diff is purely additive and no
`facts_version` bump is involved.

Because one checksum document covers every platform in the release, verifying it
once settles every platform's hash together. A lockfile written on any machine
therefore carries verified hashes for the rest of a team and for CI.

## How the check is made

The signature is verified in Starlark, in `//tf/toolchains/openpgp`, with no
external binary involved.

That is a deliberate choice rather than a flourish. Verification has to happen
where the facts are minted, which is inside the module extension, so whatever
performs it must be a prebuilt binary that can be downloaded rather than a
target that can be built - and no OpenPGP verifier ships one. Shelling out to
whatever `gpg` or `gpgv` happens to be installed would work on a laptop and
silently do nothing in a container, which is not a property a build should have.

Doing it directly turns out to be small. Both publishers sign with RSA-4096 and
`e = 65537`, so the exponentiation is seventeen big multiplications and Starlark
integers are arbitrary precision. The RSA check rebuilds the PKCS#1 v1.5 block
the signer should have produced and compares it whole rather than parsing the
recovered block, which is where the classic forgery bugs live.

## Adding or rotating a publisher key

Trust roots live in `tf/toolchains/openpgp/keys.bzl`, as moduli rather than as
keyrings: nothing parses armor, packet grammar or subkey binding signatures to
decide what to trust, and nothing discovers a key at build time. A release
signed by a key that is not in that file fails to verify rather than teaching
the build a new key.

Adding one means adding its modulus and exponent under its fingerprint. To check
an entry already there, fetch the publisher's key and confirm the fingerprint:

```console
$ curl -s https://www.hashicorp.com/.well-known/pgp-key.txt |
      gpg --show-keys --with-subkey-fingerprint
$ curl -sL https://get.opentofu.org/opentofu.asc |
      gpg --show-keys --with-fingerprint
```

## What this does not cover

The archive is fetched against a sha256 the signed document vouches for, so a
signature covers every platform's archive by covering the document. What remains
outstanding is narrower:

- tflint's `checksums.txt` is signed with cosign keyless, which needs a
  different verifier than the one here: Fulcio chain validation and a pinned
  certificate identity, not an RSA check. Until that lands its release is
  pinned on the release host's word.
- terraform-docs publishes no signature in any scheme, so nothing can verify it
  and no setting pretends otherwise.
- Provider packages are a separate mechanism with its own trust root, described
  in [mirror.md](mirror.md#verified-hashes); tflint rulesets are described in
  [tflint.md](tflint.md).
