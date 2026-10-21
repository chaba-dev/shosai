# Bundled fonts

These files implement the typography policy in `docs/typography.md`. Do not replace or regenerate them without updating this inventory and the corresponding license.

| File | Source | Purpose | SHA-256 |
| --- | --- | --- | --- |
| `InterVariable.ttf` | [Inter upstream](https://github.com/rsms/inter), variable TTF from the existing project assets | Latin interface text | `4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf` |
| `NotoSansJP-Variable.ttf` | [Google Fonts `NotoSansJP[wght].ttf`](https://github.com/google/fonts/blob/main/ofl/notosansjp/NotoSansJP%5Bwght%5D.ttf) | Japanese interface text, weights 100–900 | `c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f` |
| `SourceSerif4Variable-Roman.ttf` | [Source Serif release branch](https://github.com/adobe-fonts/source-serif/blob/release/VAR/SourceSerif4Variable-Roman.ttf) | Latin editorial text, weights 200–900 | `14d360ee1b76655da9276628b229e11671bc1f5d1083636144db6677d452cf55` |
| `Literata[opsz,wght].ttf` | [Google Fonts `ofl/literata`](https://github.com/google/fonts/tree/main/ofl/literata), `main` as of 2026-10-21 (Version 3.103) | Latin editorial text, weights 200–900, optical sizes 7–72 | `b41138c9373112f32abb589cc22e8674b06ed4048b0c513be922bdd26f274440` |
| `Literata-Italic[opsz,wght].ttf` | Same | Latin editorial italics | `d483dfaeba9cbf4ce71d32a52ee65df82f7e35b15fff8d1011cdb242d1fcd465` |
| `ShipporiMincho-Regular.ttf` | [Google Fonts `ofl/shipporimincho`](https://github.com/google/fonts/tree/main/ofl/shipporimincho), `main` as of 2026-10-21 (Version 3.110) | Japanese editorial text, weight 400 | `769b5269f0f9bc6534b352c0e6bd856a566e03ff788f107191c2d835863570b2` |
| `ShipporiMincho-Medium.ttf` | Same | Japanese editorial text, weight 500 | `700e505afc4cded2338eba29478a041e04c1c2ea5114fbb3e0b04e76c302c5d8` |
| `ShipporiMincho-SemiBold.ttf` | Same | Japanese editorial text, weight 600 | `bc7925544894a91466449adb73c6d943f50c3e53eb1c74d0673fe2dbafcd4d2d` |
| `ShipporiMincho-Bold.ttf` | Same | Japanese editorial text, weight 700 | `63bc4eddc74793f671c3ab827c5175e773ffbe569d0bf50ee65375ea9e3bc286` |
| `NotoSerifJP-ShosaiMark-Black.ttf` | [Google Fonts CSS text subset](https://fonts.googleapis.com/css2?family=Noto+Serif+JP:wght@900&text=%E6%9B%B8), version 34 | The brand mark’s `書` only, weight 900 | `1f30507d5c2b12380d0e13883ebf7d9958d34fdf43c47ef071d368468c0f4c61` |

Inter, Noto Sans JP, Literata and Shippori Mincho are the default type set (`docs/typography.md`); Source Serif 4 belongs to the Inter + Source Serif 4 set. All families use the SIL Open Font License 1.1, and each license is stored alongside its binaries (`LICENSE-Literata.txt`, `LICENSE-ShipporiMincho.txt`, and so on). `NotoSerifJP-ShosaiMark-Black.ttf` is intentionally limited to U+66F8 and exists only for the mark; use a full family before setting other Japanese text in Noto Serif JP.
