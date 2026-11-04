#!/usr/bin/env python3
"""First-party Apache-2.0 PDF geometry controls; Python standard library only.

No third-party text, font programs, images or other inputs. The image-only
page is a synthetic scan: two columns of raster marks and no text objects.
"""
from pathlib import Path
import zlib

ROOT = Path(__file__).parent


def stream(data, extra=b""):
    return b"<< /Length %d %s >>\nstream\n" % (len(data), extra) + data + b"\nendstream"


def write(name, objects):
    pdf = bytearray(b"%PDF-1.7\n")
    offsets = []
    for i, obj in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf.extend(b"%d 0 obj\n" % i + obj + b"\nendobj\n")
    xref = len(pdf)
    pdf.extend(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1))
    for offset in offsets:
        pdf.extend(b"%010d 00000 n \n" % offset)
    pdf.extend(b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
               % (len(objects) + 1, xref))
    (ROOT / name).write_bytes(pdf)


def main():
    # A nested form scales/translates an image with asymmetric dimensions.
    # Visible unrotated bounds: x100..120, y491..551 after CropBox.
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /Count 4 >>",
    ]
    for rotation in (0, 90, 180, 270):
        objects.append(
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            b"/CropBox [10 20 602 772] /Rotate %d " % rotation +
            b"/Resources << /XObject << /Fm 8 0 R >> /Font << /F1 7 0 R >> >> "
            b"/Contents 10 0 R >>")
    objects.extend([
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        stream(b"q 10 0 0 20 5 7 cm /Im Do Q",
               b"/Type /XObject /Subtype /Form /BBox [0 0 30 40] "
               b"/Matrix [2 0 0 3 100 200] /Resources << /XObject << /Im 9 0 R >> >>"),
        stream(bytes([0]), b"/Type /XObject /Subtype /Image /Width 1 /Height 1 "
               b"/ColorSpace /DeviceGray /BitsPerComponent 8"),
        stream(b"/Fm Do BT /F1 12 Tf 110 310 Td (Geometry control) Tj ET"),
    ])
    write("transformed-images.pdf", objects)

    width, height = 306, 396
    raster = bytearray([255] * width * height)
    for y in range(60, 345, 8):
        for x in list(range(27, 146)) + list(range(159, 278)):
            for dy in range(3):
                raster[(y + dy) * width + x] = 0
    write("scanned.pdf", [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /XObject << /Im 4 0 R >> >> /Contents 5 0 R >>",
        stream(zlib.compress(raster, 9),
               b"/Type /XObject /Subtype /Image /Width 306 /Height 396 "
               b"/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode"),
        stream(b"q 612 0 0 792 0 0 cm /Im Do Q"),
    ])

    # Real PDF painting controls: vector-only art below body text, a wider
    # vector figure above a caption, a raster figure with a text label, and
    # an axial shading outside text bounds.
    body = b"".join(
        b"BT /F1 10 Tf %d %d Td (%s body line %d with column text here) Tj ET\n"
        % (x, 650 - n * 14, side, n)
        for x, side in ((54, b"Left"), (317, b"Right")) for n in range(8))
    write("content-preservation.pdf", [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R 11 0 R] /Count 4 >>",
        *[b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
          b"/Resources << /Font << /F1 6 0 R >> /XObject << /Im 7 0 R >> >> "
          b"/Contents %d 0 R >>" % contents for contents in (8, 9, 10)],
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>",
        stream(zlib.compress(bytes([180] * 4)),
               b"/Type /XObject /Subtype /Image /Width 2 /Height 2 "
               b"/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode"),
        stream(body + b"0 g 70 350 210 80 re f"),
        stream(body + b"0 g 45 350 255 80 re f "
               b"BT /F1 10 Tf 80 330 Td (Vector caption) Tj ET"),
        stream(body + b"q 239 0 0 80 54 350 cm /Im Do Q "
               b"BT /F1 10 Tf 90 390 Td (Overlaid label) Tj ET "
               b"BT /F1 10 Tf 80 330 Td (Image caption) Tj ET"),
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 6 0 R >> /Shading << /Sh 13 0 R >> >> "
        b"/Contents 12 0 R >>",
        stream(body + b"/Sh sh"),
        b"<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [70 350 280 430] "
        b"/BBox [70 350 280 430] /Function << /FunctionType 2 /Domain [0 1] "
        b"/C0 [0 0 0] /C1 [0 0.3 0.8] /N 1 >> /Extend [false false] >>",
    ])


if __name__ == "__main__":
    main()
