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

static inkv_doc *inkv_open(fz_context *ctx, fz_stream *stream, const char *magic, const char *path, int cache, char *err) {
    inkv_doc *result = NULL;
    fz_var(result);
    fz_try(ctx) {
        result = fz_malloc_struct(ctx, inkv_doc);
        result->doc = stream ? fz_open_document_with_stream(ctx, magic, stream) : fz_open_document(ctx, path);
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

/// A document of type `magic` from memory (the bytes copied).
static inkv_doc *inkv_open_bytes(fz_context *ctx, const uint8_t *data, size_t length, const char *magic, int cache, char *err) {
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
    result = inkv_open(ctx, stream, magic, NULL, cache, err);
    fz_drop_stream(ctx, stream);
    fz_drop_buffer(ctx, buffer);
    return result;
}

inkv_doc *inkv_open_pdf(void *vctx, const uint8_t *data, size_t length, int cache, char *err) {
    return inkv_open_bytes((fz_context *)vctx, data, length, "application/pdf", cache, err);
}

inkv_doc *inkv_open_path(void *vctx, const char *path, int cache, char *err) {
    return inkv_open((fz_context *)vctx, NULL, NULL, path, cache, err);
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

static int page_chars(void *vctx, inkv_doc *d, int index, int annotations, inkv_line **lines, int *line_count,
                      inkv_char **chars, int *char_count, char *err) {
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
        if (annotations) fz_run_page(ctx, page, dev, fz_identity, NULL);
        else fz_run_page_contents(ctx, page, dev, fz_identity, NULL);
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

int inkv_page_chars(void *ctx, inkv_doc *d, int index, inkv_line **lines, int *line_count, inkv_char **chars,
                    int *char_count, char *err) {
    return page_chars(ctx, d, index, 0, lines, line_count, chars, char_count, err);
}

int inkv_page_chars_annots(void *ctx, inkv_doc *d, int index, inkv_line **lines, int *line_count, inkv_char **chars,
                           int *char_count, char *err) {
    return page_chars(ctx, d, index, 1, lines, line_count, chars, char_count, err);
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

int inkv_auth_bits(void *vctx, inkv_doc *d, const char *password) {
    fz_context *ctx = vctx;
    int bits = 0;
    fz_try(ctx) bits = fz_authenticate_password(ctx, d->doc, password ? password : "");
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        bits = 0;
    }
    return bits;
}

static pdf_document *inkv_pdf(fz_context *ctx, inkv_doc *d) {
    pdf_document *pdf = pdf_specifics(ctx, d->doc);
    if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This document isn't a PDF.");
    return pdf;
}

static void inkv_name(fz_context *ctx, pdf_obj *name, char out[32]) {
    const char *s = pdf_is_name(ctx, name) ? pdf_to_name(ctx, name) : "";
    strncpy(out, s, 31);
    out[31] = 0;
}

int inkv_encrypt_info(void *vctx, inkv_doc *d, int info[4], char filter[32], char cfm[32], char *err) {
    fz_context *ctx = vctx;
    int found = 0;
    filter[0] = 0;
    cfm[0] = 0;
    fz_try(ctx) {
        pdf_obj *e = pdf_dict_get(ctx, pdf_trailer(ctx, inkv_pdf(ctx, d)), PDF_NAME(Encrypt));
        if (pdf_is_dict(ctx, e)) {
            found = 1;
            info[0] = pdf_dict_get_int(ctx, e, PDF_NAME(V));
            info[1] = pdf_dict_get_int(ctx, e, PDF_NAME(R));
            info[2] = pdf_dict_get(ctx, e, PDF_NAME(Length)) ? pdf_dict_get_int(ctx, e, PDF_NAME(Length)) : 40;
            info[3] = pdf_dict_get_int(ctx, e, PDF_NAME(P));
            inkv_name(ctx, pdf_dict_get(ctx, e, PDF_NAME(Filter)), filter);
            pdf_obj *stmf = pdf_dict_get(ctx, e, PDF_NAME(StmF));
            if (pdf_is_name(ctx, stmf) && strcmp(pdf_to_name(ctx, stmf), "Identity") != 0) {
                pdf_obj *f = pdf_dict_get(ctx, pdf_dict_get(ctx, e, PDF_NAME(CF)), stmf);
                inkv_name(ctx, pdf_dict_get(ctx, f, PDF_NAME(CFM)), cfm);
            } else if (pdf_is_name(ctx, stmf)) {
                strcpy(cfm, "Identity");
            }
        }
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return -1;
    }
    return found;
}

int inkv_pdf_rotate(void *vctx, inkv_doc *d, const int *pages, int count, int degrees, char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) {
        pdf_document *pdf = inkv_pdf(ctx, d);
        for (int i = 0; i < count; i++) {
            pdf_obj *page = pdf_lookup_page_obj(ctx, pdf, pages[i]);
            int r = pdf_to_int(ctx, pdf_dict_get_inheritable(ctx, page, PDF_NAME(Rotate)));
            pdf_dict_put_int(ctx, page, PDF_NAME(Rotate), (((r + degrees) % 360) + 360) % 360);
        }
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

static int inkv_int_desc(const void *a, const void *b) { return *(const int *)b - *(const int *)a; }

int inkv_pdf_delete_pages(void *vctx, inkv_doc *d, const int *pages, int count, char *err) {
    fz_context *ctx = vctx;
    int *sorted = NULL;
    fz_var(sorted);
    fz_try(ctx) {
        pdf_document *pdf = inkv_pdf(ctx, d);
        sorted = fz_malloc_array(ctx, count > 0 ? count : 1, int);
        memcpy(sorted, pages, sizeof(int) * (size_t)count);
        qsort(sorted, (size_t)count, sizeof(int), inkv_int_desc);
        for (int i = 0; i < count; i++)
            if (i == 0 || sorted[i] != sorted[i - 1]) pdf_delete_page(ctx, pdf, sorted[i]);
    }
    fz_always(ctx) fz_free(ctx, sorted);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_pdf_count(void *vctx, inkv_doc *d, char *err) {
    fz_context *ctx = vctx;
    int n = -1;
    fz_try(ctx) n = pdf_count_pages(ctx, inkv_pdf(ctx, d));
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return -1;
    }
    return n;
}

int inkv_can_append(void *vctx, inkv_doc *d) {
    fz_context *ctx = vctx;
    int can = 0;
    fz_try(ctx) {
        pdf_document *pdf = inkv_pdf(ctx, d);
        can = pdf_can_be_saved_incrementally(ctx, pdf) && !pdf->repair_attempted;
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        can = 0;
    }
    return can;
}

int inkv_append_pdf(void *vctx, inkv_doc *d, const uint8_t *original, size_t original_length, uint8_t **out, size_t *length,
                    char *err) {
    fz_context *ctx = vctx;
    fz_buffer *buffer = NULL;
    fz_output *output = NULL;
    fz_var(buffer);
    fz_var(output);
    *out = NULL;
    *length = 0;
    fz_try(ctx) {
        pdf_document *pdf = inkv_pdf(ctx, d);
        pdf_write_options opts = pdf_default_write_options;
        pdf_parse_write_options(ctx, &opts, "incremental=yes,encrypt=keep");
        buffer = fz_new_buffer(ctx, original_length + 64 * 1024);
        output = fz_new_output_with_buffer(ctx, buffer);
        fz_write_data(ctx, output, original, original_length);
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

// ---- PDF objects ----

#define OBJ(o) ((pdf_obj *)(o))
#define OUT(o) ((inkv_obj *)(o))

inkv_doc *inkv_new_pdf(void *vctx, char *err) {
    fz_context *ctx = vctx;
    inkv_doc *result = NULL;
    fz_var(result);
    fz_try(ctx) {
        result = fz_malloc_struct(ctx, inkv_doc);
        result->doc = &pdf_create_document(ctx)->super;
        inkv_setup(ctx, result, 8);
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        if (result) fz_drop_document(ctx, result->doc);
        fz_free(ctx, result);
        return NULL;
    }
    return result;
}

inkv_doc *inkv_open_image(void *vctx, const uint8_t *data, size_t length, const char *magic, char *err) {
    return inkv_open_bytes((fz_context *)vctx, data, length, magic, 4, err);
}

int inkv_render_rgba(void *vctx, inkv_doc *d, int index, float scale, uint8_t **pixels, int *width, int *height, char *err) {
    fz_context *ctx = vctx;
    fz_pixmap *pix = NULL;
    fz_var(pix);
    *pixels = NULL;
    fz_try(ctx) {
        pix = fz_new_pixmap_from_display_list(ctx, inkv_list(ctx, d, index), fz_scale(scale, scale), fz_device_rgb(ctx), 1);
        int w = fz_pixmap_width(ctx, pix), h = fz_pixmap_height(ctx, pix);
        size_t stride = (size_t)fz_pixmap_stride(ctx, pix), row = (size_t)w * 4;
        uint8_t *out = malloc(row * (size_t)(h > 0 ? h : 1));
        if (!out) fz_throw(ctx, FZ_ERROR_SYSTEM, "Not enough memory for the image pixels.");
        const uint8_t *src = fz_pixmap_samples(ctx, pix);
        for (int y = 0; y < h; y++) memcpy(out + row * (size_t)y, src + stride * (size_t)y, row);
        // MuPDF's pixels are premultiplied by alpha; straight color is what an image with an /SMask stores.
        for (size_t k = 0; k < row * (size_t)h; k += 4) {
            unsigned a = out[k + 3];
            if (a == 0 || a == 255) continue;
            for (int c = 0; c < 3; c++) {
                unsigned v = out[k + c] * 255u / a;
                out[k + c] = (uint8_t)(v > 255 ? 255 : v);
            }
        }
        *pixels = out;
        *width = w;
        *height = h;
    }
    fz_always(ctx) fz_drop_pixmap(ctx, pix);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

void inkv_obj_drop(void *ctx, inkv_obj *obj) { pdf_drop_obj((fz_context *)ctx, OBJ(obj)); }

inkv_obj *inkv_obj_trailer(void *vctx, inkv_doc *d, char *err) {
    fz_context *ctx = vctx;
    pdf_obj *t = NULL;
    fz_var(t);
    fz_try(ctx) t = pdf_keep_obj(ctx, pdf_trailer(ctx, inkv_pdf(ctx, d)));
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return NULL;
    }
    return OUT(t);
}

inkv_obj *inkv_obj_page(void *vctx, inkv_doc *d, int index, char *err) {
    fz_context *ctx = vctx;
    pdf_obj *p = NULL;
    fz_var(p);
    fz_try(ctx) p = pdf_keep_obj(ctx, pdf_lookup_page_obj(ctx, inkv_pdf(ctx, d), index));
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return NULL;
    }
    return OUT(p);
}

int inkv_obj_page_number(void *vctx, inkv_doc *d, inkv_obj *obj) {
    fz_context *ctx = vctx;
    int n = -1;
    fz_try(ctx) n = pdf_is_indirect(ctx, OBJ(obj)) ? pdf_lookup_page_number(ctx, inkv_pdf(ctx, d), OBJ(obj)) : -1;
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        n = -1;
    }
    return n;
}

int inkv_obj_kind(void *vctx, inkv_obj *o) {
    fz_context *ctx = vctx;
    int kind = 0;
    fz_try(ctx) {
        pdf_obj *obj = OBJ(o);
        kind = pdf_is_bool(ctx, obj) ? 1 : pdf_is_int(ctx, obj) ? 2 : pdf_is_real(ctx, obj) ? 3 : pdf_is_name(ctx, obj) ? 4
             : pdf_is_string(ctx, obj) ? 5 : pdf_is_array(ctx, obj) ? 6 : pdf_is_dict(ctx, obj) ? 7 : 0;
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        kind = 0;
    }
    return kind;
}

int inkv_obj_is_ref(void *ctx, inkv_obj *o) { return pdf_is_indirect((fz_context *)ctx, OBJ(o)); }
int inkv_obj_num(void *ctx, inkv_obj *o) { return pdf_to_num((fz_context *)ctx, OBJ(o)); }

uintptr_t inkv_obj_identity(void *vctx, inkv_obj *o) {
    fz_context *ctx = vctx;
    uintptr_t id = 0;
    fz_try(ctx) id = (uintptr_t)pdf_resolve_indirect_chain(ctx, OBJ(o));
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        id = (uintptr_t)o;
    }
    return id;
}

int inkv_obj_is_stream(void *vctx, inkv_obj *o) {
    fz_context *ctx = vctx;
    int is = 0;
    fz_try(ctx) is = pdf_is_stream(ctx, OBJ(o));
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        is = 0;
    }
    return is;
}

int inkv_obj_bool(void *vctx, inkv_obj *o) {
    fz_context *ctx = vctx;
    int b = 0;
    fz_try(ctx) b = pdf_to_bool(ctx, OBJ(o));
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        b = 0;
    }
    return b;
}

double inkv_obj_number(void *vctx, inkv_obj *o) {
    fz_context *ctx = vctx;
    double n = 0;
    fz_try(ctx) n = pdf_is_int(ctx, OBJ(o)) ? (double)pdf_to_int64(ctx, OBJ(o)) : pdf_to_real(ctx, OBJ(o));
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        n = 0;
    }
    return n;
}

int inkv_obj_name(void *vctx, inkv_obj *o, char *out, int size) {
    fz_context *ctx = vctx;
    int ok = 0;
    out[0] = 0;
    fz_try(ctx) {
        if (pdf_is_name(ctx, OBJ(o))) {
            strncpy(out, pdf_to_name(ctx, OBJ(o)), (size_t)size - 1);
            out[size - 1] = 0;
            ok = 1;
        }
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        ok = 0;
    }
    return ok;
}

uint8_t *inkv_obj_string(void *vctx, inkv_obj *o, size_t *length) {
    fz_context *ctx = vctx;
    uint8_t *copy = NULL;
    fz_var(copy);
    *length = 0;
    fz_try(ctx) {
        if (pdf_is_string(ctx, OBJ(o))) {
            size_t n = pdf_to_str_len(ctx, OBJ(o));
            copy = malloc(n ? n : 1);
            if (copy && n) memcpy(copy, pdf_to_str_buf(ctx, OBJ(o)), n);
            *length = n;
        }
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        free(copy);
        copy = NULL;
    }
    return copy;
}

char *inkv_obj_text(void *vctx, inkv_obj *o) {
    fz_context *ctx = vctx;
    char *copy = NULL;
    fz_var(copy);
    fz_try(ctx) {
        if (pdf_is_string(ctx, OBJ(o))) copy = inkv_strdup(pdf_to_text_string(ctx, OBJ(o)));
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        copy = NULL;
    }
    return copy;
}

int inkv_obj_count(void *vctx, inkv_obj *o) {
    fz_context *ctx = vctx;
    int n = 0;
    fz_try(ctx) n = pdf_is_array(ctx, OBJ(o)) ? pdf_array_len(ctx, OBJ(o)) : pdf_is_dict(ctx, OBJ(o)) ? pdf_dict_len(ctx, OBJ(o)) : 0;
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        n = 0;
    }
    return n;
}

inkv_obj *inkv_obj_at(void *vctx, inkv_obj *o, int index) {
    fz_context *ctx = vctx;
    pdf_obj *v = NULL;
    fz_var(v);
    fz_try(ctx) v = pdf_keep_obj(ctx, pdf_array_get(ctx, OBJ(o), index));
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        v = NULL;
    }
    return OUT(v);
}

char *inkv_obj_key_at(void *vctx, inkv_obj *o, int index) {
    fz_context *ctx = vctx;
    char *key = NULL;
    fz_var(key);
    fz_try(ctx) {
        pdf_obj *k = pdf_dict_get_key(ctx, OBJ(o), index);
        if (pdf_is_name(ctx, k)) key = inkv_strdup(pdf_to_name(ctx, k));
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        key = NULL;
    }
    return key;
}

inkv_obj *inkv_obj_value_at(void *vctx, inkv_obj *o, int index) {
    fz_context *ctx = vctx;
    pdf_obj *v = NULL;
    fz_var(v);
    fz_try(ctx) v = pdf_keep_obj(ctx, pdf_dict_get_val(ctx, OBJ(o), index));
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        v = NULL;
    }
    return OUT(v);
}

inkv_obj *inkv_obj_get(void *vctx, inkv_obj *o, const char *key) {
    fz_context *ctx = vctx;
    pdf_obj *v = NULL;
    fz_var(v);
    fz_try(ctx) v = pdf_keep_obj(ctx, pdf_dict_gets(ctx, OBJ(o), key));
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        v = NULL;
    }
    return OUT(v);
}

int inkv_obj_put(void *vctx, inkv_obj *o, const char *key, inkv_obj *value, char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) {
        if (value) pdf_dict_puts(ctx, OBJ(o), key, OBJ(value));
        else pdf_dict_dels(ctx, OBJ(o), key);
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_obj_array_put(void *vctx, inkv_obj *o, int index, inkv_obj *value, char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) pdf_array_put(ctx, OBJ(o), index, OBJ(value));
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_obj_array_insert(void *vctx, inkv_obj *o, int index, inkv_obj *value, char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) {
        if (index >= pdf_array_len(ctx, OBJ(o))) pdf_array_push(ctx, OBJ(o), OBJ(value));
        else pdf_array_insert(ctx, OBJ(o), OBJ(value), index);
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_obj_array_delete(void *vctx, inkv_obj *o, int index, char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) pdf_array_delete(ctx, OBJ(o), index);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

inkv_obj *inkv_obj_new(void *vctx, inkv_doc *d, int kind, double number, const char *text, const uint8_t *bytes, size_t length,
                       char *err) {
    fz_context *ctx = vctx;
    pdf_obj *v = NULL;
    fz_var(v);
    fz_try(ctx) {
        pdf_document *pdf = inkv_pdf(ctx, d);
        switch (kind) {
        case 1: v = number != 0 ? PDF_TRUE : PDF_FALSE; break;
        case 2: v = pdf_new_int(ctx, (int64_t)number); break;
        case 3: v = pdf_new_real(ctx, (float)number); break;
        case 4: v = pdf_new_name(ctx, text ? text : ""); break;
        case 5: v = pdf_new_string(ctx, (const char *)bytes, length); break;
        case 6: v = pdf_new_array(ctx, pdf, 4); break;
        case 7: v = pdf_new_dict(ctx, pdf, 4); break;
        case 8: v = pdf_new_text_string(ctx, text ? text : ""); break;
        default: v = PDF_NULL; break;
        }
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return NULL;
    }
    return OUT(v);
}

inkv_obj *inkv_obj_add(void *vctx, inkv_doc *d, inkv_obj *o, char *err) {
    fz_context *ctx = vctx;
    pdf_obj *ref = NULL;
    fz_var(ref);
    fz_try(ctx) ref = pdf_add_object(ctx, inkv_pdf(ctx, d), OBJ(o));
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return NULL;
    }
    return OUT(ref);
}

inkv_obj *inkv_obj_ref(void *vctx, inkv_doc *d, int num, char *err) {
    fz_context *ctx = vctx;
    pdf_obj *ref = NULL;
    fz_var(ref);
    fz_try(ctx) ref = pdf_new_indirect(ctx, inkv_pdf(ctx, d), num, 0);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return NULL;
    }
    return OUT(ref);
}

int inkv_obj_xref_len(void *vctx, inkv_doc *d) {
    fz_context *ctx = vctx;
    int n = 0;
    fz_try(ctx) n = pdf_xref_len(ctx, inkv_pdf(ctx, d));
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        n = 0;
    }
    return n;
}

uint8_t *inkv_obj_stream(void *vctx, inkv_doc *d, inkv_obj *o, int raw, size_t *length, char *err) {
    fz_context *ctx = vctx;
    fz_buffer *buf = NULL;
    uint8_t *copy = NULL;
    fz_var(buf);
    fz_var(copy);
    *length = 0;
    (void)d;
    fz_try(ctx) {
        buf = raw ? pdf_load_raw_stream(ctx, OBJ(o)) : pdf_load_stream(ctx, OBJ(o));
        unsigned char *bytes = NULL;
        size_t n = fz_buffer_storage(ctx, buf, &bytes);
        copy = malloc(n ? n : 1);
        if (!copy) fz_throw(ctx, FZ_ERROR_SYSTEM, "Not enough memory for the stream.");
        if (n) memcpy(copy, bytes, n);
        *length = n;
    }
    fz_always(ctx) fz_drop_buffer(ctx, buf);
    fz_catch(ctx) {
        free(copy);
        inkv_error(ctx, err);
        return NULL;
    }
    return copy;
}

/// The bytes as a stream stores them: deflated (zlib) when asked. Throws.
static fz_buffer *inkv_stream_buffer(fz_context *ctx, const uint8_t *bytes, size_t length, int deflate) {
    if (!deflate) return fz_new_buffer_from_copied_data(ctx, bytes, length);
    size_t bound = fz_deflate_bound(ctx, length);
    unsigned char *out = fz_malloc(ctx, bound ? bound : 1);
    size_t n = bound;
    fz_try(ctx) fz_deflate(ctx, out, &n, bytes, length, FZ_DEFLATE_DEFAULT);
    fz_catch(ctx) {
        fz_free(ctx, out);
        fz_rethrow(ctx);
    }
    return fz_new_buffer_from_data(ctx, out, n);
}

inkv_obj *inkv_obj_add_stream(void *vctx, inkv_doc *d, inkv_obj *dict, const uint8_t *bytes, size_t length, int deflate,
                              char *err) {
    fz_context *ctx = vctx;
    fz_buffer *buf = NULL;
    pdf_obj *made = NULL, *ref = NULL;
    fz_var(buf);
    fz_var(made);
    fz_var(ref);
    fz_try(ctx) {
        pdf_document *pdf = inkv_pdf(ctx, d);
        pdf_obj *use = OBJ(dict);
        if (!use) use = made = pdf_new_dict(ctx, pdf, 4);
        if (deflate) {
            pdf_dict_put(ctx, use, PDF_NAME(Filter), PDF_NAME(FlateDecode));
            pdf_dict_del(ctx, use, PDF_NAME(DecodeParms));
        }
        buf = inkv_stream_buffer(ctx, bytes, length, deflate);
        ref = pdf_add_stream(ctx, pdf, buf, use, 1);
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buf);
        pdf_drop_obj(ctx, made);
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return NULL;
    }
    return OUT(ref);
}

int inkv_obj_set_stream(void *vctx, inkv_doc *d, inkv_obj *o, const uint8_t *bytes, size_t length, int deflate, char *err) {
    fz_context *ctx = vctx;
    fz_buffer *buf = NULL;
    fz_var(buf);
    fz_try(ctx) {
        pdf_document *pdf = inkv_pdf(ctx, d);
        if (deflate) pdf_dict_put(ctx, OBJ(o), PDF_NAME(Filter), PDF_NAME(FlateDecode));
        else pdf_dict_del(ctx, OBJ(o), PDF_NAME(Filter));
        pdf_dict_del(ctx, OBJ(o), PDF_NAME(DecodeParms));
        buf = inkv_stream_buffer(ctx, bytes, length, deflate);
        pdf_update_stream(ctx, pdf, OBJ(o), buf, 1);
    }
    fz_always(ctx) fz_drop_buffer(ctx, buf);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_page_insert(void *vctx, inkv_doc *d, int at, inkv_obj *page, char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) pdf_insert_page(ctx, inkv_pdf(ctx, d), at, OBJ(page));
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

inkv_graft *inkv_graft_new(void *vctx, inkv_doc *dst, char *err) {
    fz_context *ctx = vctx;
    pdf_graft_map *map = NULL;
    fz_var(map);
    fz_try(ctx) map = pdf_new_graft_map(ctx, inkv_pdf(ctx, dst));
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return NULL;
    }
    return (inkv_graft *)map;
}

void inkv_graft_drop(void *ctx, inkv_graft *map) { pdf_drop_graft_map((fz_context *)ctx, (pdf_graft_map *)map); }

int inkv_graft_page(void *vctx, inkv_graft *map, int to, inkv_doc *src, int from, char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) pdf_graft_mapped_page(ctx, (pdf_graft_map *)map, to, inkv_pdf(ctx, src), from);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

inkv_obj *inkv_graft_obj(void *vctx, inkv_graft *map, inkv_obj *obj, char *err) {
    fz_context *ctx = vctx;
    pdf_obj *copy = NULL;
    fz_var(copy);
    fz_try(ctx) copy = pdf_graft_mapped_object(ctx, (pdf_graft_map *)map, OBJ(obj));
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return NULL;
    }
    return OUT(copy);
}
