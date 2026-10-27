// Inkvolt PDF's C shim over MuPDF. MuPDF signals errors with fz_try/fz_catch (setjmp/longjmp), which must never unwind
// through Swift: each function here runs its MuPDF calls inside fz_try and, on an error, returns a failure value and
// copies MuPDF's message into `err` (at least INKV_ERR_SIZE bytes). A context and the documents opened in it are used
// by one thread at a time (PdfCore's engine serializes them).
#ifndef INKV_MUPDF_SHIM_H
#define INKV_MUPDF_SHIM_H

#include <stddef.h>
#include <stdint.h>

#define INKV_ERR_SIZE 256

typedef struct inkv_doc inkv_doc;

/// A MuPDF context with the default allocator and resource store; NULL when MuPDF can't make one.
void *inkv_new_context(void);
void inkv_drop_context(void *ctx);

/// Opens a PDF from memory (the bytes are copied). NULL on failure, with the reason in err.
inkv_doc *inkv_open_pdf(void *ctx, const uint8_t *data, size_t length, char *err);
void inkv_drop_doc(void *ctx, inkv_doc *doc);

/// 1 when the document needs a password before its pages can be read.
int inkv_needs_password(void *ctx, inkv_doc *doc);
/// 0: wrong; 1: opened as user; 2: as owner (MuPDF's fz_authenticate_password bits, collapsed).
int inkv_authenticate(void *ctx, inkv_doc *doc, const char *password);

/// The page count, or -1 on failure.
int inkv_count_pages(void *ctx, inkv_doc *doc, char *err);

/// The page's bounds in points as drawn (rotation applied): x0, y0, x1, y1. 0 on failure.
int inkv_page_bounds(void *ctx, inkv_doc *doc, int page, float out[4], char *err);

/// Draws the page at `scale` into an RGB pixmap without alpha; the pixels (width * height * 3 bytes, rows packed) are
/// malloc'ed and owned by the caller (free with inkv_free). 0 on failure.
int inkv_render_rgb(void *ctx, inkv_doc *doc, int page, float scale, uint8_t **pixels, int *width, int *height, char *err);

/// The page's text as UTF-8 (malloc'ed; free with inkv_free), lines separated by '\n'. NULL on failure.
char *inkv_page_text(void *ctx, inkv_doc *doc, int page, char *err);

void inkv_free(void *p);

#endif
