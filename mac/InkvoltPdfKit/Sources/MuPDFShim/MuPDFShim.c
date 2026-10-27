#include "MuPDFShim.h"

#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <stdlib.h>
#include <string.h>

struct inkv_doc {
    fz_document *doc;
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

void *inkv_new_context(void) {
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
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

inkv_doc *inkv_open_pdf(void *vctx, const uint8_t *data, size_t length, char *err) {
    fz_context *ctx = vctx;
    fz_buffer *buffer = NULL;
    fz_stream *stream = NULL;
    inkv_doc *result = NULL;
    fz_var(buffer);
    fz_var(stream);
    fz_var(result);
    fz_try(ctx) {
        buffer = fz_new_buffer_from_copied_data(ctx, data, length);
        stream = fz_open_buffer(ctx, buffer);
        result = fz_malloc_struct(ctx, inkv_doc);
        result->doc = fz_open_document_with_stream(ctx, "application/pdf", stream);
    }
    fz_always(ctx) {
        fz_drop_stream(ctx, stream);
        fz_drop_buffer(ctx, buffer);
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        fz_free(ctx, result);
        return NULL;
    }
    return result;
}

void inkv_drop_doc(void *vctx, inkv_doc *doc) {
    fz_context *ctx = vctx;
    if (!doc) return;
    fz_drop_document(ctx, doc->doc);
    fz_free(ctx, doc);
}

int inkv_needs_password(void *vctx, inkv_doc *doc) {
    fz_context *ctx = vctx;
    int needs = 0;
    fz_try(ctx) needs = fz_needs_password(ctx, doc->doc);
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        needs = 0;
    }
    return needs;
}

int inkv_authenticate(void *vctx, inkv_doc *doc, const char *password) {
    fz_context *ctx = vctx;
    int bits = 0;
    fz_try(ctx) bits = fz_authenticate_password(ctx, doc->doc, password);
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        bits = 0;
    }
    if (bits & 4) return 2; // owner
    return bits ? 1 : 0;
}

int inkv_count_pages(void *vctx, inkv_doc *doc, char *err) {
    fz_context *ctx = vctx;
    int count = -1;
    fz_try(ctx) count = fz_count_pages(ctx, doc->doc);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return -1;
    }
    return count;
}

int inkv_page_bounds(void *vctx, inkv_doc *doc, int index, float out[4], char *err) {
    fz_context *ctx = vctx;
    fz_page *page = NULL;
    fz_var(page);
    fz_try(ctx) {
        page = fz_load_page(ctx, doc->doc, index);
        fz_rect r = fz_bound_page(ctx, page);
        out[0] = r.x0;
        out[1] = r.y0;
        out[2] = r.x1;
        out[3] = r.y1;
    }
    fz_always(ctx) fz_drop_page(ctx, page);
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_render_rgb(void *vctx, inkv_doc *doc, int index, float scale, uint8_t **pixels, int *width, int *height, char *err) {
    fz_context *ctx = vctx;
    fz_pixmap *pix = NULL;
    fz_var(pix);
    *pixels = NULL;
    fz_try(ctx) {
        pix = fz_new_pixmap_from_page_number(ctx, doc->doc, index, fz_scale(scale, scale), fz_device_rgb(ctx), 0);
        int w = fz_pixmap_width(ctx, pix), h = fz_pixmap_height(ctx, pix);
        size_t stride = (size_t)fz_pixmap_stride(ctx, pix), row = (size_t)w * 3;
        uint8_t *out = malloc(row * (size_t)h);
        if (!out) fz_throw(ctx, FZ_ERROR_SYSTEM, "out of memory for the page's pixels");
        const uint8_t *src = fz_pixmap_samples(ctx, pix);
        for (int y = 0; y < h; y++) memcpy(out + row * (size_t)y, src + stride * (size_t)y, row);
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

char *inkv_page_text(void *vctx, inkv_doc *doc, int index, char *err) {
    fz_context *ctx = vctx;
    fz_stext_page *text = NULL;
    fz_buffer *buffer = NULL;
    char *result = NULL;
    fz_var(text);
    fz_var(buffer);
    fz_var(result);
    fz_try(ctx) {
        text = fz_new_stext_page_from_page_number(ctx, doc->doc, index, NULL);
        buffer = fz_new_buffer_from_stext_page(ctx, text);
        size_t length = fz_buffer_storage(ctx, buffer, NULL);
        result = malloc(length + 1);
        if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "out of memory for the page's text");
        unsigned char *bytes = NULL;
        fz_buffer_storage(ctx, buffer, &bytes);
        memcpy(result, bytes, length);
        result[length] = 0;
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buffer);
        fz_drop_stext_page(ctx, text);
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        free(result);
        return NULL;
    }
    return result;
}

void inkv_free(void *p) { free(p); }
