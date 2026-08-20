# EPUB conformance fixtures

These complete EPUB 3 test containers provide shared, backend-neutral inputs
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
`resource-limits` book uses a 1 MiB repetitive resource by default;
`--large-resource-bytes` and `--compress-stress-resource` can produce a
temporary compressed variant for testing specific size and compression-ratio
limits. Stress variants are not expected to match the checked-in hashes.

The fixture-contract tests assert source semantics, not renderer-specific pixel
output. A backend must preserve those semantics before screenshots can count as
supporting evidence.
