#!/usr/bin/env python3
"""Generate deterministic, redistribution-safe EPUB performance workloads."""

from pathlib import Path
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[3]
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
LOREM = (
    "Shōsai keeps a stable logical reading position while the renderer lays out "
    "this deliberately repetitive paragraph. Mixed punctuation, emphasized words, "
    "and enough text to wrap across several lines make the fixture useful for "
    "repeatable pagination measurements without importing copyrighted material. "
)


def write_entry(
    archive: zipfile.ZipFile,
    name: str,
    content: str | bytes,
    compression: int = zipfile.ZIP_STORED,
) -> None:
    info = zipfile.ZipInfo(name, ZIP_TIMESTAMP)
    info.compress_type = compression
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    archive.writestr(info, content)


def write_epub(path: Path, workload: str) -> None:
    chapter_count = 16
    chapters = []
    manifest = [
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
        '<item id="css" href="style.css" media-type="text/css"/>',
    ]
    spine = []

    for index in range(chapter_count):
        chapter_id = f"chapter-{index + 1}"
        chapter_path = f"chapter{index + 1}.xhtml"
        manifest.append(
            f'<item id="{chapter_id}" href="{chapter_path}" media-type="application/xhtml+xml"/>'
        )
        spine.append(f'<itemref idref="{chapter_id}"/>')
        if workload == "text":
            body = f"<p>{LOREM * 300}<strong>End of chapter {index + 1}.</strong></p>"
        else:
            body = "\n".join(
                f'<figure><img src="images/page.png" alt="Generated workload image"/>'
                f"<figcaption>Image {image + 1} in chapter {index + 1}. {LOREM}</figcaption></figure>"
                for image in range(24)
            )
        chapters.append(
            (
                chapter_path,
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
                f"<title>Chapter {index + 1}</title>"
                '<link rel="stylesheet" type="text/css" href="style.css"/>'
                f"</head><body><h1>Chapter {index + 1}</h1>{body}</body></html>"
            )
        )

    if workload == "image":
        manifest.append(
            '<item id="page-image" href="images/page.png" media-type="image/png"/>'
        )

    nav_items = "\n".join(
        f'<li><a href="chapter{index + 1}.xhtml">Chapter {index + 1}</a></li>'
        for index in range(chapter_count)
    )
    nav = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>'
        f'<body><nav epub:type="toc"><ol>{nav_items}</ol></nav></body></html>'
    )
    package = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        f"<dc:identifier id=\"book-id\">shosai-perf-{workload}</dc:identifier>"
        f"<dc:title>Shōsai {workload.title()} Performance Fixture</dc:title>"
        '<dc:language>en</dc:language></metadata>'
        f"<manifest>{''.join(manifest)}</manifest><spine>{''.join(spine)}</spine></package>"
    )
    container = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>'
    )
    css = (
        "body { font-family: serif; line-height: 1.55; } "
        "p { margin: 0 0 0.8em; } figure { margin: 1em auto; text-align: center; } "
        "img { max-width: 100%; height: auto; }"
    )

    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        write_entry(archive, "mimetype", "application/epub+zip")
        write_entry(archive, "META-INF/container.xml", container)
        write_entry(archive, "OEBPS/content.opf", package)
        write_entry(archive, "OEBPS/nav.xhtml", nav)
        write_entry(archive, "OEBPS/style.css", css)
        for chapter_path, content in chapters:
            write_entry(archive, f"OEBPS/{chapter_path}", content)
        if workload == "image":
            write_entry(
                archive,
                "OEBPS/images/page.png",
                (ROOT / "assets" / "shosai-icon.png").read_bytes(),
            )


def main() -> None:
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "target" / "epub-perf-fixtures"
    write_epub(output / "large-text.epub", "text")
    write_epub(output / "large-image.epub", "image")
    print(output)


if __name__ == "__main__":
    main()
