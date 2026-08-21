# EPUB conformance fixtures

These EPUB 3 test containers provide shared, backend-neutral inputs
for the native and Wry renderer evaluations. Some intentionally contain
malformed markup, corrupt resources, or hostile references and are not expected
to pass EPUBCheck. They contain only generated text, a tiny generated PNG, and
the repository's generated Shosai font fixtures. No content from commercial
books is included.

Regenerate deterministically from the repository root:

```sh
python3 crates/shosai-core/tests/fixtures/epub-conformance/generate.py
```

Every checked-in entry is stored without compression and has a fixed timestamp
and stable ordering, with `mimetype` first. `SHA256SUMS` therefore remains
reproducible without depending on a particular zlib implementation. The
`resource-limits` book uses separate 1 MiB repetitive font and text resources
by default; only the text resource is compressed by the stress option.
`--large-resource-bytes` and `--compress-stress-resource` can produce a
temporary compressed variant for testing specific size and compression-ratio
limits. Stress variants are not expected to match the checked-in hashes.

The checked-in matrix contains twelve books expected to open and three archives
expected to fail at a declared parser boundary (an oversized declared image, a
missing spine resource, and a duplicate ZIP entry). It supplies semantic source
oracles and representative negative shapes; configurable-limit tests cover
input, entry count, compression ratio, per-entry and aggregate bytes, XML
bytes/depth/text, font bytes, and decoded image dimensions/bytes. Stress
variants are generated temporarily against the production budgets.

The fixture-contract tests assert source semantics, not renderer-specific pixel
output. A backend must preserve those semantics before screenshots can count as
supporting evidence.
