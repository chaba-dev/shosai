# Bundled fonts

These files implement the typography policy in `docs/typography.md`. Do not replace or regenerate them without updating this inventory and the corresponding license.

| File | Source | Purpose | SHA-256 |
| --- | --- | --- | --- |
| `InterVariable.ttf` | [Inter upstream](https://github.com/rsms/inter), variable TTF from the existing project assets | Latin interface text | `4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf` |
| `NotoSansJP-Variable.ttf` | [Google Fonts `NotoSansJP[wght].ttf`](https://github.com/google/fonts/blob/main/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf) | Japanese interface text, weights 100–900 | `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f` |
| `SourceSerif4Variable-Roman.ttf` | [Source Serif release branch](https://github.com/adobe-fonts/source-serif/blob/release/VAR/SourceSerif4Variable-Roman.ttf) | Latin editorial text, weights 200–900 | `14d360ee1b76655da9276628b229e11671bc1f5d1083636144db6677d452cf55` |
| `NotoSerifJP-ShosaiMark-Regular.ttf` | [Google Fonts CSS text subset](https://fonts.googleapis.com/css2?family=Noto+Serif+JP:wght@400&text=%E6%9B%B8), version 33 | Website wordmark glyph `書` only | `8ecace995946627dd90e74dddaed727e66304dff9f619adc2446de78b469a9a8` |

All four families use the SIL Open Font License 1.1. Their licenses are stored alongside the binaries. `NotoSerifJP-ShosaiMark-Regular.ttf` is intentionally limited to U+66F8; use the full upstream Noto Serif JP family before adding other Japanese editorial text.
