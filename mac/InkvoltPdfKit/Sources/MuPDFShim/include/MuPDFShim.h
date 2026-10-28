// Inkvolt PDF's C shim over MuPDF. MuPDF signals errors with fz_try/fz_catch (setjmp/longjmp), which must never unwind
// through Swift: each function here runs its MuPDF calls inside fz_try and, on an error, returns a failure value and
// copies MuPDF's message into `err` (at least INKV_ERR_SIZE bytes). A context and the documents opened in it are used
// by one thread at a time (PdfCore's engine serializes them); a cookie may be aborted from any thread.
#ifndef INKV_MUPDF_SHIM_H
#define INKV_MUPDF_SHIM_H

#include <stddef.h>
#include <stdint.h>

#define INKV_ERR_SIZE 256

typedef struct inkv_doc inkv_doc;
typedef struct inkv_cookie inkv_cookie;

/// A character from a page's text: its code point, the box of its quad (MuPDF page space) and MuPDF's flags for it
/// (16 filled, 32 stroked, 64 clipped: neither of the first two for text drawn invisibly, render mode 3).
typedef struct {
    int c;
    float x0, y0, x1, y1;
    int flags;
} inkv_char;

/// A line of a page's text: its characters [first, first + count) and its baseline direction.
typedef struct {
    int first, count;
    float dx, dy;
} inkv_line;

/// A link: its area (MuPDF page space); an internal one's page (else -1) and target y (NAN when the destination names
/// no position); an external one's URI (NULL for internal links).
typedef struct {
    float x0, y0, x1, y1;
    int page;
    float y;
    char *uri;
} inkv_link;

/// An outline entry, in reading order with its depth (0 at the top): title, page (-1 when it leads nowhere), target y.
typedef struct {
    char *title;
    int page;
    float y;
    int depth;
} inkv_outline_item;

/// A MuPDF context with the default allocator and a resource store of `store_bytes`; NULL when MuPDF can't make one.
void *inkv_new_context(size_t store_bytes);
void inkv_drop_context(void *ctx);

/// Opens a PDF from memory (the bytes are copied), or a file in place. NULL on failure, with the reason in err. The
/// document keeps its `cache` most recently used pages loaded, with their display lists.
inkv_doc *inkv_open_pdf(void *ctx, const uint8_t *data, size_t length, int cache, char *err);
inkv_doc *inkv_open_path(void *ctx, const char *path, int cache, char *err);
void inkv_drop_doc(void *ctx, inkv_doc *doc);

/// 1 when the document needs a password before its pages can be read.
int inkv_needs_password(void *ctx, inkv_doc *doc);
/// 0: wrong; 1: opened as user; 2: as owner (MuPDF's fz_authenticate_password bits, collapsed).
int inkv_authenticate(void *ctx, inkv_doc *doc, const char *password);
/// 1 when the PDF is encrypted (an open password or only a permissions one).
int inkv_is_encrypted(void *ctx, inkv_doc *doc);

/// The page count, or -1 on failure.
int inkv_count_pages(void *ctx, inkv_doc *doc, char *err);
/// The page's bounds in MuPDF page space (rotation applied): x0, y0, x1, y1. 0 on failure.
int inkv_page_bounds(void *ctx, inkv_doc *doc, int page, float out[4], char *err);
/// Test hook: pages and display lists the document holds loaded right now.
void inkv_loaded(inkv_doc *doc, int *pages, int *lists);

/// A cookie to stop a render midway: inkv_cookie_abort may be called from another thread while it runs.
inkv_cookie *inkv_new_cookie(void);
void inkv_cookie_abort(inkv_cookie *cookie);
void inkv_drop_cookie(inkv_cookie *cookie);

/// Draws an area of the page (MuPDF page space) at `scale` pixels per point, with its annotations, into RGB without
/// alpha on white; the pixels (width * height * 3 bytes, rows packed) are malloc'ed for the caller (inkv_free).
/// 1: drawn; 2: stopped by the cookie (no pixels); 0: failed.
int inkv_render_rgb(void *ctx, inkv_doc *doc, int page, float scale, float x0, float y0, float x1, float y1,
                    inkv_cookie *cookie, uint8_t **pixels, int *width, int *height, char *err);

/// The whole page at `scale`, with its annotations, written as a PNG or a JPEG (quality 90). 0 on failure.
int inkv_save_image(void *ctx, inkv_doc *doc, int page, float scale, const char *path, int jpeg, char *err);

/// The page's text without its annotations: lines and characters (malloc'ed; inkv_free each). 0 on failure.
int inkv_page_chars(void *ctx, inkv_doc *doc, int page, inkv_line **lines, int *line_count, inkv_char **chars,
                    int *char_count, char *err);
/// The same with the page's annotations and widgets drawn in (their appearances' text too).
int inkv_page_chars_annots(void *ctx, inkv_doc *doc, int page, inkv_line **lines, int *line_count, inkv_char **chars,
                           int *char_count, char *err);

/// The page's text as UTF-8 (malloc'ed; inkv_free), lines separated by '\n'. NULL on failure.
char *inkv_page_text(void *ctx, inkv_doc *doc, int page, char *err);

/// The page's links (inkv_free_links). 0 on failure.
int inkv_page_links(void *ctx, inkv_doc *doc, int page, inkv_link **links, int *count, char *err);
void inkv_free_links(inkv_link *links, int count);

/// The document's outline, flattened (inkv_free_outline). An empty outline is 1 with count 0. 0 on failure.
int inkv_outline(void *ctx, inkv_doc *doc, inkv_outline_item **items, int *count, char *err);
void inkv_free_outline(inkv_outline_item *items, int count);

/// The PDF written out whole with MuPDF's write options ("garbage,compress", "encrypt=aes-256,user-password=…");
/// the bytes are malloc'ed for the caller (inkv_free). 0 on failure.
int inkv_write_pdf(void *ctx, inkv_doc *doc, const char *options, uint8_t **out, size_t *length, char *err);


// Editing (the role PDFsharp has on Windows): a document opened with inkv_open_pdf, changed through these, then written
// with inkv_write_pdf (a whole new file) or inkv_append_pdf (an incremental update after the original bytes).

/// fz_authenticate_password's bits as they are: 1 no password needed, 2 the user password, 4 the owner password; 0 wrong.
int inkv_auth_bits(void *ctx, inkv_doc *doc, const char *password);

/// The encryption dictionary: info = V, R, Length, P; its /Filter and the crypt method of its /StmF filter (/CFM; empty
/// when none). 1: encrypted; 0: not; -1: failed.
int inkv_encrypt_info(void *ctx, inkv_doc *doc, int info[4], char filter[32], char cfm[32], char *err);

/// Turns pages by `degrees` (a multiple of 90) on top of their /Rotate. 0 on failure.
int inkv_pdf_rotate(void *ctx, inkv_doc *doc, const int *pages, int count, int degrees, char *err);

/// Deletes pages (indices in any order). 0 on failure.
int inkv_pdf_delete_pages(void *ctx, inkv_doc *doc, const int *pages, int count, char *err);

/// The page count as the PDF has it now (after edits). -1 on failure.
int inkv_pdf_count(void *ctx, inkv_doc *doc, char *err);

/// 1 when MuPDF can append an update to the document (not repaired, opened from bytes).
int inkv_can_append(void *ctx, inkv_doc *doc);

/// The original bytes followed by an incremental update holding the edits (encryption kept); malloc'ed (inkv_free).
int inkv_append_pdf(void *ctx, inkv_doc *doc, const uint8_t *original, size_t original_length, uint8_t **out, size_t *length,
                    char *err);

// ---- PDF objects (D3 on): what PDFsharp's object model is on Windows, over MuPDF's pdf_obj. Every object a function
// returns is the caller's (inkv_obj_drop); objects of documents opened in the same context can be grafted between them.
// Reading resolves indirect references; an object that can't be read reads as null.

typedef struct inkv_obj inkv_obj;
typedef struct inkv_graft inkv_graft;

/// An empty PDF (no pages), for merging and images.
inkv_doc *inkv_new_pdf(void *ctx, char *err);
/// An image file opened as a document (MuPDF's image handler; `magic` such as "image/png"); one page per frame.
inkv_doc *inkv_open_image(void *ctx, const uint8_t *data, size_t length, const char *magic, char *err);
/// Draws a page at `scale` into straight (not premultiplied) RGBA on transparency; malloc'ed (inkv_free). 0 on failure.
int inkv_render_rgba(void *ctx, inkv_doc *doc, int page, float scale, uint8_t **pixels, int *width, int *height, char *err);

void inkv_obj_drop(void *ctx, inkv_obj *obj);
inkv_obj *inkv_obj_trailer(void *ctx, inkv_doc *doc, char *err);
/// The page's object (an indirect reference). NULL on failure.
inkv_obj *inkv_obj_page(void *ctx, inkv_doc *doc, int index, char *err);
/// The index of the page an object (a reference to a page object) is, or -1.
int inkv_obj_page_number(void *ctx, inkv_doc *doc, inkv_obj *obj);
/// 0 null (or missing, or unreadable), 1 bool, 2 int, 3 real, 4 name, 5 string, 6 array, 7 dict (a stream is a dict).
int inkv_obj_kind(void *ctx, inkv_obj *obj);
int inkv_obj_is_ref(void *ctx, inkv_obj *obj);
int inkv_obj_num(void *ctx, inkv_obj *obj);
/// The resolved object's address: identifies a direct object while it lives.
uintptr_t inkv_obj_identity(void *ctx, inkv_obj *obj);
int inkv_obj_is_stream(void *ctx, inkv_obj *obj);
int inkv_obj_bool(void *ctx, inkv_obj *obj);
double inkv_obj_number(void *ctx, inkv_obj *obj);
/// The name without its slash, copied into out; 0 when it isn't a name.
int inkv_obj_name(void *ctx, inkv_obj *obj, char *out, int size);
/// A string's bytes (malloc'ed); NULL when it isn't a string.
uint8_t *inkv_obj_string(void *ctx, inkv_obj *obj, size_t *length);
/// A string decoded as text (PDFDocEncoding or UTF-16), as UTF-8 (malloc'ed); NULL when it isn't a string.
char *inkv_obj_text(void *ctx, inkv_obj *obj);
/// An array's length or a dictionary's number of entries; 0 otherwise.
int inkv_obj_count(void *ctx, inkv_obj *obj);
inkv_obj *inkv_obj_at(void *ctx, inkv_obj *array, int index);
/// A dictionary's key (malloc'ed) and value at `index`.
char *inkv_obj_key_at(void *ctx, inkv_obj *dict, int index);
inkv_obj *inkv_obj_value_at(void *ctx, inkv_obj *dict, int index);
/// A dictionary's value for `key` (no slash); NULL when missing.
inkv_obj *inkv_obj_get(void *ctx, inkv_obj *dict, const char *key);
/// Sets (or, with value NULL, removes) a dictionary entry. 0 on failure.
int inkv_obj_put(void *ctx, inkv_obj *dict, const char *key, inkv_obj *value, char *err);
int inkv_obj_array_put(void *ctx, inkv_obj *array, int index, inkv_obj *value, char *err);
/// Inserts at `index` (the length appends).
int inkv_obj_array_insert(void *ctx, inkv_obj *array, int index, inkv_obj *value, char *err);
int inkv_obj_array_delete(void *ctx, inkv_obj *array, int index, char *err);
/// A new direct object: kind as inkv_obj_kind (bool, int and real from `number`, name from `text`, string from `bytes`),
/// or 8: a text string from UTF-8 `text` (PDFDocEncoding when it fits, else UTF-16).
inkv_obj *inkv_obj_new(void *ctx, inkv_doc *doc, int kind, double number, const char *text, const uint8_t *bytes, size_t length,
                       char *err);
/// A new indirect object holding `obj`; returns the reference.
inkv_obj *inkv_obj_add(void *ctx, inkv_doc *doc, inkv_obj *obj, char *err);
/// A reference to object `num` (for walking every object).
inkv_obj *inkv_obj_ref(void *ctx, inkv_doc *doc, int num, char *err);
int inkv_obj_xref_len(void *ctx, inkv_doc *doc);
/// A stream's data, decoded, or with `raw` as the file stores it (still encoded); malloc'ed. NULL on failure.
uint8_t *inkv_obj_stream(void *ctx, inkv_doc *doc, inkv_obj *obj, int raw, size_t *length, char *err);
/// A new stream object (returns its reference): `dict`'s entries (may be NULL) and the bytes, deflated when `deflate`
/// (/Filter /FlateDecode), else kept as they are (already encoded as `dict` says).
inkv_obj *inkv_obj_add_stream(void *ctx, inkv_doc *doc, inkv_obj *dict, const uint8_t *bytes, size_t length, int deflate,
                              char *err);
/// Replaces a stream's data, as inkv_obj_add_stream stores it. 0 on failure.
int inkv_obj_set_stream(void *ctx, inkv_doc *doc, inkv_obj *stream, const uint8_t *bytes, size_t length, int deflate, char *err);

/// Inserts a page object (a reference) into the page tree before page `at` (the count appends). 0 on failure.
int inkv_page_insert(void *ctx, inkv_doc *doc, int at, inkv_obj *page, char *err);

/// Copies between documents opened in the same context, each source object once per map.
inkv_graft *inkv_graft_new(void *ctx, inkv_doc *dst, char *err);
void inkv_graft_drop(void *ctx, inkv_graft *map);
/// Source page `from` copied (its contents, resources and boxes, not its annotations) as page `to` of the map's document.
int inkv_graft_page(void *ctx, inkv_graft *map, int to, inkv_doc *src, int from, char *err);
/// A source object copied into the map's document, with everything it refers to.
inkv_obj *inkv_graft_obj(void *ctx, inkv_graft *map, inkv_obj *obj, char *err);

void inkv_free(void *p);

// ---- Export (D5c): what Export to Word, Excel and text reads from a page (MuPDFCore's structured text with
// PreserveImages and CollectVectors on Windows).

/// A character: its code point, its quad's box (MuPDF page space), size, color (sRGB, alpha in the top byte) and font
/// (an index into the page's fonts, -1 when it has none).
typedef struct {
    int c;
    float x0, y0, x1, y1;
    float size;
    uint32_t argb;
    int font;
} inkv_echar;

/// A font the page's characters use: its name (malloc'ed) and MuPDF's flags for it.
typedef struct {
    char *name;
    int bold, italic, serif, mono;
} inkv_efont;

/// A picture: where it is drawn, its own pixel size, and its pixels encoded as PNG, or as JPEG (quality 85) when `jpeg`;
/// data NULL when MuPDF couldn't encode it (an unusual color space: the caller renders it instead).
typedef struct {
    float x0, y0, x1, y1;
    int width, height;
    int jpeg;
    uint8_t *data;
    size_t length;
} inkv_eimage;

/// A vector path's bounds, and whether it is stroked (else filled).
typedef struct {
    float x0, y0, x1, y1;
    int stroked;
} inkv_evector;

/// A page read for export: text lines (their characters [first, first + count)), fonts, pictures and vector paths, in
/// the order MuPDF's blocks come. Free with inkv_free_export.
typedef struct {
    inkv_line *lines;
    int line_count;
    inkv_echar *chars;
    int char_count;
    inkv_efont *fonts;
    int font_count;
    inkv_eimage *images;
    int image_count;
    inkv_evector *vectors;
    int vector_count;
} inkv_export;

/// Reads a page for export, with its annotations drawn in: pictures (encoded, when `images`; JPEG for those of more than
/// `jpeg_above` pixels) and vector paths are collected too. 0 on failure.
int inkv_export_page(void *ctx, inkv_doc *doc, int page, int images, long long jpeg_above, inkv_export *out, char *err);
void inkv_free_export(inkv_export *e);

/// Draws an area of the page (MuPDF page space) at `scale`, with its annotations, on transparency, as straight (not
/// premultiplied) RGBA; malloc'ed (inkv_free). 0 on failure.
int inkv_render_region_rgba(void *ctx, inkv_doc *doc, int page, float scale, float x0, float y0, float x1, float y1,
                            uint8_t **pixels, int *width, int *height, char *err);

#endif
