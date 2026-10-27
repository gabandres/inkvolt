#include "MuPDFShim.h"

#include <math.h>
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <stdlib.h>
#include <string.h>

/// An open document and the pages it keeps loaded: at most `capacity`, the least recently used freed first (with
/// their display lists), so memory stays bounded however far a long document is scrolled.
struct inkv_doc {
    fz_document *doc;
    int count;
    int capacity;
    int loaded;
    fz_page **pages;
    fz_display_list **lists;
    unsigned *used;
    unsigned clock;
};

struct inkv_cookie {
    fz_cookie cookie;
};

/// Copies the caught error's message for Swift and marks it handled (MuPDF warns of errors a catch leaves unreported).
static void inkv_error(fz_context *ctx, char *err) {
    if (err) {
        const char *message = fz_caught_message(ctx);
        strncpy(err, message ? message : "MuPDF failed", INKV_ERR_SIZE - 1);
        err[INKV_ERR_SIZE - 1] = 0;
    }
    fz_ignore_error(ctx);
}

static char *inkv_strdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *copy = malloc(n);
    if (copy) memcpy(copy, s, n);
    return copy;
}

void *inkv_new_context(size_t store_bytes) {
    fz_context *ctx = fz_new_context(NULL, NULL, store_bytes ? store_bytes : FZ_STORE_DEFAULT);
    if (!ctx) return NULL;
    // Errors reach Swift through the shim's messages; MuPDF's own printing to stderr (errors, repair warnings) is off.
    fz_set_error_callback(ctx, NULL, NULL);
    fz_set_warning_callback(ctx, NULL, NULL);
    fz_try(ctx) fz_register_document_handlers(ctx);
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        fz_drop_context(ctx);
        return NULL;
    }
    return ctx;
}

void inkv_drop_context(void *ctx) { fz_drop_context((fz_context *)ctx); }

/// The page count and the page cache, once the document is open. Throws.
static void inkv_setup(fz_context *ctx, inkv_doc *d, int cache) {
    d->capacity = cache > 0 ? cache : 32;
    // A document that needs a password can't count its pages yet: counted after inkv_authenticate.
    d->count = fz_needs_password(ctx, d->doc) ? 0 : fz_count_pages(ctx, d->doc);
}

/// The arrays for `count` pages (made on first use, after a password may have opened the document). Throws.
static void inkv_arrays(fz_context *ctx, inkv_doc *d) {
    if (d->pages) return;
    if (d->count == 0) d->count = fz_count_pages(ctx, d->doc);
    size_t n = d->count > 0 ? (size_t)d->count : 1;
    d->pages = fz_calloc(ctx, n, sizeof(fz_page *));
    d->lists = fz_calloc(ctx, n, sizeof(fz_display_list *));
    d->used = fz_calloc(ctx, n, sizeof(unsigned));
}

static void inkv_unload(fz_context *ctx, inkv_doc *d, int i) {
    fz_drop_display_list(ctx, d->lists[i]);
    d->lists[i] = NULL;
    fz_drop_page(ctx, d->pages[i]);
    d->pages[i] = NULL;
    d->loaded--;
}

/// The page, loaded (and marked as just used); frees the least recently used one beyond the capacity. Throws.
static fz_page *inkv_page(fz_context *ctx, inkv_doc *d, int i) {
    inkv_arrays(ctx, d);
    if (i < 0 || i >= d->count) fz_throw(ctx, FZ_ERROR_ARGUMENT, "There is no page %d.", i + 1);
    if (!d->pages[i]) {
        while (d->loaded >= d->capacity) {
            int oldest = -1;
            for (int k = 0; k < d->count; k++)
                if (d->pages[k] && (oldest < 0 || d->used[k] < d->used[oldest])) oldest = k;
            if (oldest < 0) break;
            inkv_unload(ctx, d, oldest);
        }
        d->pages[i] = fz_load_page(ctx, d->doc, i);
        d->loaded++;
    }
    d->used[i] = ++d->clock;
    return d->pages[i];
}

/// The page's display list (made once while the page stays loaded). Throws.
static fz_display_list *inkv_list(fz_context *ctx, inkv_doc *d, int i) {
    fz_page *page = inkv_page(ctx, d, i);
    if (!d->lists[i]) d->lists[i] = fz_new_display_list_from_page(ctx, page);
    return d->lists[i];
}

static inkv_doc *inkv_open(fz_context *ctx, fz_stream *stream, const char *path, int cache, char *err) {
    inkv_doc *result = NULL;
    fz_var(result);
    fz_try(ctx) {
        result = fz_malloc_struct(ctx, inkv_doc);
        result->doc = stream ? fz_open_document_with_stream(ctx, "application/pdf", stream) : fz_open_document(ctx, path);
        inkv_setup(ctx, result, cache);
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        if (result) fz_drop_document(ctx, result->doc);
        fz_free(ctx, result);
        return NULL;
    }
    return result;
}

inkv_doc *inkv_open_pdf(void *vctx, const uint8_t *data, size_t length, int cache, char *err) {
    fz_context *ctx = vctx;
    fz_buffer *buffer = NULL;
    fz_stream *stream = NULL;
    inkv_doc *result = NULL;
    fz_var(buffer);
    fz_var(stream);
    fz_try(ctx) {
        buffer = fz_new_buffer_from_copied_data(ctx, data, length);
        stream = fz_open_buffer(ctx, buffer);
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, buffer);
        inkv_error(ctx, err);
        return NULL;
    }
    result = inkv_open(ctx, stream, NULL, cache, err);
    fz_drop_stream(ctx, stream);
    fz_drop_buffer(ctx, buffer);
    return result;
}

inkv_doc *inkv_open_path(void *vctx, const char *path, int cache, char *err) {
    return inkv_open((fz_context *)vctx, NULL, path, cache, err);
}

void inkv_drop_doc(void *vctx, inkv_doc *d) {
    fz_context *ctx = vctx;
    if (!d) return;
    if (d->pages)
        for (int i = 0; i < d->count; i++)
            if (d->pages[i]) inkv_unload(ctx, d, i);
    fz_free(ctx, d->pages);
    fz_free(ctx, d->lists);
    fz_free(ctx, d->used);
    fz_drop_document(ctx, d->doc);
    fz_free(ctx, d);
}

int inkv_needs_password(void *vctx, inkv_doc *d) {
    fz_context *ctx = vctx;
    int needs = 0;
    fz_try(ctx) needs = fz_needs_password(ctx, d->doc);
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        needs = 0;
    }
    return needs;
}

int inkv_authenticate(void *vctx, inkv_doc *d, const char *password) {
    fz_context *ctx = vctx;
    int bits = 0;
    fz_try(ctx) bits = fz_authenticate_password(ctx, d->doc, password);
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        bits = 0;
    }
    if (bits & 4) return 2; // owner
    return bits ? 1 : 0;
}

int inkv_is_encrypted(void *vctx, inkv_doc *d) {
    fz_context *ctx = vctx;
    int encrypted = 0;
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        encrypted = pdf && pdf_dict_get(ctx, pdf_trailer(ctx, pdf), PDF_NAME(Encrypt)) != NULL;
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        encrypted = 0;
    }
    return encrypted;
}

int inkv_count_pages(void *vctx, inkv_doc *d, char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) inkv_arrays(ctx, d);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return -1;
    }
    return d->count;
}

int inkv_page_bounds(void *vctx, inkv_doc *d, int index, float out[4], char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) {
        fz_rect r = fz_bound_page(ctx, inkv_page(ctx, d, index));
        out[0] = r.x0;
        out[1] = r.y0;
        out[2] = r.x1;
        out[3] = r.y1;
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

void inkv_loaded(inkv_doc *d, int *pages, int *lists) {
    *pages = 0;
    *lists = 0;
    if (!d->pages) return;
    for (int i = 0; i < d->count; i++) {
        if (d->pages[i]) (*pages)++;
        if (d->lists[i]) (*lists)++;
    }
}

inkv_cookie *inkv_new_cookie(void) { return calloc(1, sizeof(inkv_cookie)); }
void inkv_cookie_abort(inkv_cookie *c) {
    if (c) c->cookie.abort = 1;
}
void inkv_drop_cookie(inkv_cookie *c) { free(c); }

int inkv_render_rgb(void *vctx, inkv_doc *d, int index, float scale, float x0, float y0, float x1, float y1,
                    inkv_cookie *cookie, uint8_t **pixels, int *width, int *height, char *err) {
    fz_context *ctx = vctx;
    fz_pixmap *pix = NULL;
    fz_device *dev = NULL;
    int aborted = 0;
    fz_var(pix);
    fz_var(dev);
    fz_var(aborted);
    *pixels = NULL;
    fz_try(ctx) {
        fz_display_list *list = inkv_list(ctx, d, index);
        fz_matrix ctm = fz_scale(scale, scale);
        fz_rect area = fz_make_rect(x0, y0, x1, y1);
        fz_irect box = fz_round_rect(fz_transform_rect(area, ctm));
        pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), box, NULL, 0);
        fz_clear_pixmap_with_value(ctx, pix, 255);
        dev = fz_new_draw_device(ctx, fz_identity, pix);
        fz_run_display_list(ctx, list, dev, ctm, fz_transform_rect(area, ctm), cookie ? &cookie->cookie : NULL);
        fz_close_device(ctx, dev);
        if (cookie && cookie->cookie.abort) {
            aborted = 1;
        } else {
            int w = fz_pixmap_width(ctx, pix), h = fz_pixmap_height(ctx, pix);
            size_t stride = (size_t)fz_pixmap_stride(ctx, pix), row = (size_t)w * 3;
            uint8_t *out = malloc(row * (size_t)(h > 0 ? h : 1));
            if (!out) fz_throw(ctx, FZ_ERROR_SYSTEM, "There isn't enough memory for the page's pixels.");
            const uint8_t *src = fz_pixmap_samples(ctx, pix);
            for (int y = 0; y < h; y++) memcpy(out + row * (size_t)y, src + stride * (size_t)y, row);
            *pixels = out;
            *width = w;
            *height = h;
        }
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_pixmap(ctx, pix);
    }
    fz_catch(ctx) {
        if (cookie && cookie->cookie.abort) {
            fz_ignore_error(ctx);
            return 2;
        }
        inkv_error(ctx, err);
        return 0;
    }
    return aborted ? 2 : 1;
}

int inkv_save_image(void *vctx, inkv_doc *d, int index, float scale, const char *path, int jpeg, char *err) {
    fz_context *ctx = vctx;
    fz_pixmap *pix = NULL;
    fz_var(pix);
    fz_try(ctx) {
        fz_display_list *list = inkv_list(ctx, d, index);
        pix = fz_new_pixmap_from_display_list(ctx, list, fz_scale(scale, scale), fz_device_rgb(ctx), 0);
        if (jpeg) fz_save_pixmap_as_jpeg(ctx, pix, path, 90);
        else fz_save_pixmap_as_png(ctx, pix, path);
    }
    fz_always(ctx) fz_drop_pixmap(ctx, pix);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_page_chars(void *vctx, inkv_doc *d, int index, inkv_line **lines, int *line_count, inkv_char **chars,
                    int *char_count, char *err) {
    fz_context *ctx = vctx;
    fz_stext_page *text = NULL;
    fz_device *dev = NULL;
    inkv_line *ls = NULL;
    inkv_char *cs = NULL;
    fz_var(text);
    fz_var(dev);
    fz_var(ls);
    fz_var(cs);
    *lines = NULL;
    *chars = NULL;
    *line_count = 0;
    *char_count = 0;
    fz_try(ctx) {
        fz_page *page = inkv_page(ctx, d, index);
        fz_stext_options options = { 0 };
        text = fz_new_stext_page(ctx, fz_bound_page(ctx, page));
        dev = fz_new_stext_device(ctx, text, &options);
        fz_run_page_contents(ctx, page, dev, fz_identity, NULL);
        fz_close_device(ctx, dev);
        int nl = 0, nc = 0;
        for (fz_stext_block *b = text->first_block; b; b = b->next) {
            if (b->type != FZ_STEXT_BLOCK_TEXT) continue;
            for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
                nl++;
                for (fz_stext_char *c = l->first_char; c; c = c->next) nc++;
            }
        }
        ls = malloc(sizeof(inkv_line) * (size_t)(nl ? nl : 1));
        cs = malloc(sizeof(inkv_char) * (size_t)(nc ? nc : 1));
        if (!ls || !cs) fz_throw(ctx, FZ_ERROR_SYSTEM, "There isn't enough memory for the page's text.");
        int li = 0, ci = 0;
        for (fz_stext_block *b = text->first_block; b; b = b->next) {
            if (b->type != FZ_STEXT_BLOCK_TEXT) continue;
            for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
                ls[li].first = ci;
                ls[li].dx = l->dir.x;
                ls[li].dy = l->dir.y;
                for (fz_stext_char *c = l->first_char; c; c = c->next) {
                    fz_rect r = fz_rect_from_quad(c->quad);
                    cs[ci].c = c->c;
                    cs[ci].x0 = r.x0;
                    cs[ci].y0 = r.y0;
                    cs[ci].x1 = r.x1;
                    cs[ci].y1 = r.y1;
                    ci++;
                }
                ls[li].count = ci - ls[li].first;
                li++;
            }
        }
        *lines = ls;
        *chars = cs;
        *line_count = nl;
        *char_count = nc;
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_stext_page(ctx, text);
    }
    fz_catch(ctx) {
        free(ls);
        free(cs);
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

char *inkv_page_text(void *vctx, inkv_doc *d, int index, char *err) {
    fz_context *ctx = vctx;
    fz_stext_page *text = NULL;
    fz_buffer *buffer = NULL;
    char *result = NULL;
    fz_var(text);
    fz_var(buffer);
    fz_var(result);
    fz_try(ctx) {
        text = fz_new_stext_page_from_page(ctx, inkv_page(ctx, d, index), NULL);
        buffer = fz_new_buffer_from_stext_page(ctx, text);
        unsigned char *bytes = NULL;
        size_t length = fz_buffer_storage(ctx, buffer, &bytes);
        result = malloc(length + 1);
        if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "There isn't enough memory for the page's text.");
        if (length) memcpy(result, bytes, length);
        result[length] = 0;
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buffer);
        fz_drop_stext_page(ctx, text);
    }
    fz_catch(ctx) {
        free(result);
        inkv_error(ctx, err);
        return NULL;
    }
    return result;
}

void inkv_free_links(inkv_link *links, int count) {
    if (!links) return;
    for (int i = 0; i < count; i++) free(links[i].uri);
    free(links);
}

int inkv_page_links(void *vctx, inkv_doc *d, int index, inkv_link **links, int *count, char *err) {
    fz_context *ctx = vctx;
    fz_link *first = NULL;
    inkv_link *out = NULL;
    int n = 0;
    fz_var(first);
    fz_var(out);
    fz_var(n);
    *links = NULL;
    *count = 0;
    fz_try(ctx) {
        first = fz_load_links(ctx, inkv_page(ctx, d, index));
        int total = 0;
        for (fz_link *l = first; l; l = l->next) total++;
        out = calloc((size_t)(total ? total : 1), sizeof(inkv_link));
        if (!out) fz_throw(ctx, FZ_ERROR_SYSTEM, "There isn't enough memory for the page's links.");
        for (fz_link *l = first; l; l = l->next) {
            if (!l->uri) continue;
            inkv_link *k = &out[n];
            k->x0 = l->rect.x0;
            k->y0 = l->rect.y0;
            k->x1 = l->rect.x1;
            k->y1 = l->rect.y1;
            k->page = -1;
            k->y = NAN;
            if (fz_is_external_link(ctx, l->uri)) {
                k->uri = inkv_strdup(l->uri);
            } else {
                float x = NAN, y = NAN;
                fz_location loc = fz_resolve_link(ctx, d->doc, l->uri, &x, &y);
                k->page = fz_page_number_from_location(ctx, d->doc, loc);
                k->y = y;
            }
            n++;
        }
        *links = out;
        *count = n;
    }
    fz_always(ctx) fz_drop_link(ctx, first);
    fz_catch(ctx) {
        inkv_free_links(out, n);
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

void inkv_free_outline(inkv_outline_item *items, int count) {
    if (!items) return;
    for (int i = 0; i < count; i++) free(items[i].title);
    free(items);
}

static int inkv_outline_count(fz_outline *o) {
    int n = 0;
    for (; o; o = o->next) n += 1 + inkv_outline_count(o->down);
    return n;
}

static void inkv_outline_fill(fz_context *ctx, fz_document *doc, fz_outline *o, int depth, inkv_outline_item *items, int *n) {
    for (; o; o = o->next) {
        inkv_outline_item *item = &items[(*n)++];
        item->title = inkv_strdup(o->title ? o->title : "");
        item->page = fz_page_number_from_location(ctx, doc, o->page);
        item->y = o->y;
        item->depth = depth;
        inkv_outline_fill(ctx, doc, o->down, depth + 1, items, n);
    }
}

int inkv_outline(void *vctx, inkv_doc *d, inkv_outline_item **items, int *count, char *err) {
    fz_context *ctx = vctx;
    fz_outline *outline = NULL;
    inkv_outline_item *out = NULL;
    int n = 0;
    fz_var(outline);
    fz_var(out);
    fz_var(n);
    *items = NULL;
    *count = 0;
    fz_try(ctx) {
        outline = fz_load_outline(ctx, d->doc);
        int total = inkv_outline_count(outline);
        out = calloc((size_t)(total ? total : 1), sizeof(inkv_outline_item));
        if (!out) fz_throw(ctx, FZ_ERROR_SYSTEM, "There isn't enough memory for the outline.");
        inkv_outline_fill(ctx, d->doc, outline, 0, out, &n);
        *items = out;
        *count = n;
    }
    fz_always(ctx) fz_drop_outline(ctx, outline);
    fz_catch(ctx) {
        inkv_free_outline(out, n);
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_write_pdf(void *vctx, inkv_doc *d, const char *options, uint8_t **out, size_t *length, char *err) {
    fz_context *ctx = vctx;
    fz_buffer *buffer = NULL;
    fz_output *output = NULL;
    fz_var(buffer);
    fz_var(output);
    *out = NULL;
    *length = 0;
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This document isn't a PDF.");
        pdf_write_options opts = pdf_default_write_options;
        pdf_parse_write_options(ctx, &opts, options ? options : "");
        buffer = fz_new_buffer(ctx, 64 * 1024);
        output = fz_new_output_with_buffer(ctx, buffer);
        pdf_write_document(ctx, pdf, output, &opts);
        fz_close_output(ctx, output);
        unsigned char *bytes = NULL;
        size_t n = fz_buffer_storage(ctx, buffer, &bytes);
        uint8_t *copy = malloc(n ? n : 1);
        if (!copy) fz_throw(ctx, FZ_ERROR_SYSTEM, "There isn't enough memory to write the PDF.");
        if (n) memcpy(copy, bytes, n);
        *out = copy;
        *length = n;
    }
    fz_always(ctx) {
        fz_drop_output(ctx, output);
        fz_drop_buffer(ctx, buffer);
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

void inkv_free(void *p) { free(p); }
