# Catalog category artwork

Browse has one bundled, transparent cover collage for each of the 72 categories
in the published Gutenberg snapshot. The titles and counts stay live Flutter
text, not pixels in the image. Bundled artwork works without a network request.
New categories without a bundled image retain their live member-cover previews.

`categories/sources.json` records every category, both selected member books,
the original catalog cover URL, the mirror download URL, the upstream RDF
rights statement and the source/output SHA-256 hashes. Familiar covers from the
chosen mock are preferred only when the books belong to that actual category.
For other categories, candidates are checked in numeric Gutenberg-ID order.
The generator rejects automatic neon/pastel jackets, non-portrait internal
banners and mostly blank title pages, and skips identical cover files within
each pair rather than repeating one series jacket. These image heuristics are
a shortlist, not a design review: inspect every selected jacket and rendered
tile after regeneration. The explicit mock selections have already been
visually curated.

The generator checks each selected book's RDF identity and requires the exact
source statement **Public domain in the USA.** It skips copyrighted or unstated
rights rather than treating the CSV's missing rights as permission. This does
not establish public-domain status outside the USA. Cover images and associated
Project Gutenberg marks remain subject to the source's terms; the full upstream
license is retained in `LICENSE-GUTENBERG.txt` and included in Flutter's notices.
The license text was extracted from Gutenberg book 1342's EPUB on its listed
mirror, <https://gutenberg.pglaf.org/cache/epub/1342/pg1342.epub>.

Regenerate from an installed, verified catalog, using an owned download cache:

```sh
.agents/dev python3 scripts/generate-catalog-category-art.py \
  path/to/catalog.sqlite3 .amp/in/orb-backup/catalog-category-art-sources
```

The Nix-provided ImageMagick compositor preserves the actual cover pixels,
rotates and overlaps two covers, adds shadows and crops them at the card edge.
It does not redraw book artwork or lettering. It checks candidates until two
suitable members are found for each category; downloads are bounded to two
concurrent requests, cached and identified with Shōsai's User-Agent.

Ordinary book covers remain on-demand images, not 78,518 bundled thumbnails:
the app tries the catalog URL, then the same cover on the Gutenberg-listed
mirror, then its existing typographic fallback if both are unavailable. No
acquisition URLs or published catalog files are changed by this artwork.
