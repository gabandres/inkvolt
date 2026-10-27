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

/// A character from a page's text: its code point and the box of its quad (MuPDF page space).
typedef struct {
    int c;
    float x0, y0, x1, y1;
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

void inkv_free(void *p);

#endif
