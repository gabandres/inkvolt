#include "MuPDFShim.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdatomic.h>
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// ---- Bounds on a page's reading (roadmap: "A hostile file's time", the Mac's half) ----
//
// MuPDF's cookie is looked at between a content stream's operators and a display list's nodes, not while it inflates:
// 4 GB of zeros Flate-encoded twice into a 7 KB page is one lexer call that skips white space for a minute. So a call
// that reads a page's content gives its cookie a time budget and a largest picture, and two places look at them:
// - the document's own stream (`inkv_source`), which hands MuPDF the file's bytes in small chunks while a call reads, so
//   however much they inflate to, MuPDF asks again within milliseconds; past the budget, or once cancelled, it throws
//   FZ_ERROR_TRYLATER, which MuPDF passes up through its filters and object loading as "not available yet" (its
//   progressive loading) without repairing the file or keeping anything half read;
// - a device between the page and its target (`inkv_guard`), which looks at the time at each drawing call (nested
//   forms drawn a billion times read nothing), refuses a picture larger than the cap before anything decodes it
//   (MuPDF inflates all of a picture's pixels for every draw, whatever the zoom: 1.2 GB for a 20,000 x 20,000 one), and,
//   in front of a draw device, a pattern whose tiles would take longer to draw than the time left (the draw device
//   draws them all inside one call);
// - before a page is read, its streams (`inkv_check_streams`): one decompressed more than twice in a row is refused, as
//   the stream's bound above can't see what its inner filters make (four Flates make terabytes of each byte read).
// The time is the reading thread's own (CPU time): waiting for the disk or for other threads isn't the page's cost.

#define INKV_STOP_CANCELLED 1
#define INKV_STOP_SLOW 2
#define INKV_STOP_LARGE 3
#define INKV_STOP_FILTERS 4

struct inkv_cookie {
    fz_cookie cookie;      // its abort is set from any thread, never cleared once a cancel set it
    double seconds;        // a part's reading budget (the reading, then the drawing); 0: none
    double max_pixels;     // the largest picture, width x height; 0: none
    double deadline;       // the thread's CPU time at which the current part's time is up; 0: none
    atomic_int cancelled;  // set from any thread by inkv_cookie_abort
    atomic_int stopped;    // INKV_STOP_*: why the call stopped, once it did
};

/// The calling thread's CPU time: a call runs on one thread, and the time it waits isn't counted.
static double inkv_cpu(void) { return (double)clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1e9; }

/// MuPDF's own flag, which it reads between operators and display-list nodes.
static void inkv_set_abort(inkv_cookie *c) { __atomic_store_n(&c->cookie.abort, 1, __ATOMIC_SEQ_CST); }

/// Stops the call for `why` (unless it already stopped for another reason): throws `code`.
static void inkv_stop(fz_context *ctx, inkv_cookie *c, int why, int code, const char *message) {
    int none = 0;
    atomic_compare_exchange_strong(&c->stopped, &none, why);
    inkv_set_abort(c);
    fz_throw(ctx, code, "%s", message);
}

/// Stops the call (throws `code`, the cookie aborted) once it was cancelled or its time is up; nothing otherwise.
static void inkv_watch(fz_context *ctx, inkv_cookie *c, int code) {
    if (!c) return;
    if (!atomic_load(&c->stopped)) {
        if (atomic_load(&c->cancelled)) atomic_store(&c->stopped, INKV_STOP_CANCELLED);
        else if (c->deadline > 0 && inkv_cpu() > c->deadline) atomic_store(&c->stopped, INKV_STOP_SLOW);
        else return;
    }
    inkv_set_abort(c);
    fz_throw(ctx, code, "The page's reading was stopped.");
}

/// The bytes a document reads: in place in memory, or from a file. While a call reads (`active`), at most `chunk`
/// bytes at a time, starting at 16 and growing while MuPDF uses them up quickly.
typedef struct {
    const unsigned char *data; // NULL for a file
    fz_buffer *owned;          // the copy `data` points into, if the document has its own
    int fd;                    // -1 for bytes in memory
    int64_t length;
    int64_t pos;               // where the next chunk starts
    int64_t next_at;           // where the last chunk ended: reading on from there keeps the chunk's size
    inkv_cookie *active;
    size_t chunk;
    double last;               // the reading thread's CPU time when it was handed the last chunk
    double delay;              // test hook: seconds each read waits while a call reads (a slow share)
    unsigned char buffer[16384];
} inkv_source;

#define INKV_CHUNK_MAX 16384

static int inkv_source_next(fz_context *ctx, fz_stream *stm, size_t max) {
    inkv_source *s = stm->state;
    (void)max;
    if (s->pos >= s->length) return EOF;
    // Between calls: the rest of the bytes in memory at once, as fz_open_buffer does; a file's buffer full.
    size_t left = (size_t)(s->length - s->pos);
    size_t n = s->fd >= 0 && left > INKV_CHUNK_MAX ? INKV_CHUNK_MAX : left;
    if (s->active) {
        inkv_watch(ctx, s->active, FZ_ERROR_TRYLATER);
        // Reading somewhere else (another object, another stream) starts small again: chunks grown on the page's
        // quick objects would hand MuPDF a whole 7 KB bomb at once. A chunk that took MuPDF long to use up (its own
        // time since it was handed over: a slow disk or a busy machine doesn't count) may have inflated a lot: the
        // next ones are smaller, so the time is looked at often.
        double spent = inkv_cpu() - s->last;
        if (s->pos != s->next_at) s->chunk = 16;
        else if (spent > 0.004) s->chunk = s->chunk > 16 ? s->chunk / 16 : 1;
        else if (s->chunk < INKV_CHUNK_MAX) s->chunk *= 2;
        if (n > s->chunk) n = s->chunk;
        if (s->delay > 0) usleep((useconds_t)(s->delay * 1e6));
    }
    if (s->fd >= 0) {
        ssize_t got;
        do got = pread(s->fd, s->buffer, n, s->pos);
        while (got < 0 && errno == EINTR);
        if (got < 0) fz_throw(ctx, FZ_ERROR_SYSTEM, "The file couldn't be read: %s", strerror(errno));
        if (got == 0) return EOF;
        n = (size_t)got;
        stm->rp = s->buffer;
    } else {
        stm->rp = (unsigned char *)s->data + s->pos;
    }
    stm->wp = stm->rp + n;
    s->pos += (int64_t)n;
    s->next_at = s->pos;
    stm->pos = s->pos;
    if (s->active) s->last = inkv_cpu();
    return *stm->rp++;
}

static void inkv_source_seek(fz_context *ctx, fz_stream *stm, int64_t offset, int whence) {
    inkv_source *s = stm->state;
    (void)ctx;
    int64_t at = whence == 2 ? s->length + offset : whence == 1 ? stm->pos - (stm->wp - stm->rp) + offset : offset;
    if (at < 0) at = 0;
    if (at > s->length) at = s->length;
    s->pos = at;
    stm->pos = at;
    stm->rp = stm->wp = s->fd >= 0 ? s->buffer : (unsigned char *)s->data + at;
}

static void inkv_source_drop(fz_context *ctx, void *state) {
    inkv_source *s = state;
    if (s->fd >= 0) close(s->fd);
    fz_drop_buffer(ctx, s->owned);
    fz_free(ctx, s);
}

/// A stream over bytes (`owned` kept while it lives, when given) or a file descriptor (closed with it, or here when
/// the stream can't be made). Throws.
static fz_stream *inkv_new_source(fz_context *ctx, const unsigned char *data, int64_t length, fz_buffer *owned, int fd,
                                  inkv_source **out) {
    inkv_source *s = NULL;
    fz_try(ctx) s = fz_malloc_struct(ctx, inkv_source);
    fz_catch(ctx) {
        if (fd >= 0) close(fd);
        fz_rethrow(ctx);
    }
    s->data = data;
    s->owned = fz_keep_buffer(ctx, owned);
    s->fd = fd;
    s->length = length;
    s->chunk = INKV_CHUNK_MAX;
    fz_stream *stm = fz_new_stream(ctx, s, inkv_source_next, inkv_source_drop); // drops s if it throws
    stm->seek = inkv_source_seek;
    *out = s;
    return stm;
}

/// A device in front of another: the call's time looked at with each drawing call, every picture's size checked; in
/// front of a draw device (`drawing`), every pattern's tiles counted too.
typedef struct {
    fz_device super;
    fz_device *target;
    inkv_cookie *cookie;
    unsigned calls;      // the clock is read every 64 calls (72,000 paths a sheet read it 150,000 times: 4% of Find)
    int drawing;
    fz_matrix transform; // the draw device's own, from what it is handed to its pixels
    fz_irect pixels;     // the draw device's pixels
} inkv_guard;

// What drawing a pattern's tile costs the draw device, each tile and each of its pixels: on an M1 MacBook Air, 194 M tiles of
// 81 pixels (a 1-point cell every 0.05 point at 600 dpi) took 16-17 s, 85 ns a tile.
#define INKV_TILE_SECONDS 30e-9
#define INKV_TILE_PIXEL_SECONDS 0.7e-9

#define TARGET(dev) (((inkv_guard *)(dev))->target)

// A drawing call that opens or closes nothing goes straight to the target's own function: MuPDF's fz_fill_path and
// the like only add a second fz_try per call (the guard's own call has one), which cost Find on the drawing set 10%.
// Calls that open or close a clip, mask, group or tile go through MuPDF's, which keeps the target's container stack.
#define FORWARD(dev, fn, ...) \
    do { \
        fz_device *t_ = TARGET(dev); \
        if (t_->fn) t_->fn(ctx, t_, __VA_ARGS__); \
    } while (0)

static void guard_check(fz_context *ctx, fz_device *dev) {
    inkv_guard *g = (inkv_guard *)dev;
    inkv_cookie *c = g->cookie;
    if (atomic_load(&c->stopped) || atomic_load(&c->cancelled) || (++g->calls & 63) == 0) inkv_watch(ctx, c, FZ_ERROR_ABORT);
}

/// Refuses a picture (or its soft mask) of more pixels than the cookie allows, before MuPDF decodes any of it; the
/// time is looked at before every picture, as decoding one can take a second.
static void guard_picture(fz_context *ctx, fz_device *dev, fz_image *image) {
    inkv_cookie *c = ((inkv_guard *)dev)->cookie;
    inkv_watch(ctx, c, FZ_ERROR_ABORT);
    for (int depth = 0; image && depth < 4 && c->max_pixels > 0; depth++, image = image->mask)
        if ((double)image->w * (double)image->h > c->max_pixels)
            inkv_stop(ctx, c, INKV_STOP_LARGE, FZ_ERROR_ABORT, "A picture on the page is too large.");
}

/// Refuses a pattern whose tiles would take the draw device longer than the part's time left: it draws every tile
/// inside one call (its end of the tile), which nothing stops. The tiles are counted over what its pixels show of the
/// area, as the draw device counts them, each the size of the pattern's cell (a cell larger than its step overlaps).
static void guard_tiles(fz_context *ctx, fz_device *dev, fz_rect area, fz_rect view, float xstep, float ystep, fz_matrix ctm) {
    inkv_guard *g = (inkv_guard *)dev;
    inkv_cookie *c = g->cookie;
    inkv_watch(ctx, c, FZ_ERROR_ABORT);
    if (!g->drawing || c->deadline <= 0) return;
    fz_matrix m = fz_concat(ctm, g->transform); // pattern space to pixels
    fz_rect shown = fz_intersect_rect(area, fz_transform_rect(fz_rect_from_irect(g->pixels), fz_invert_matrix(m)));
    if (fz_is_empty_rect(shown)) return;
    double cell_w = fmax(view.x1 - view.x0, 0), cell_h = fmax(view.y1 - view.y0, 0);
    double across = (shown.x1 - shown.x0 + cell_w) / fabs((double)xstep) + 1;
    double down = (shown.y1 - shown.y0 + cell_h) / fabs((double)ystep) + 1;
    fz_rect cell = fz_transform_rect(view, m);
    double cell_pixels = fmax(cell.x1 - cell.x0, 1) * fmax(cell.y1 - cell.y0, 1);
    double cost = across * down * (INKV_TILE_SECONDS + cell_pixels * INKV_TILE_PIXEL_SECONDS);
    // A step of 0 (or not a number) gives no finite cost: refused too.
    if (!(cost <= c->deadline - inkv_cpu()))
        inkv_stop(ctx, c, INKV_STOP_SLOW, FZ_ERROR_ABORT, "A pattern on the page has too many tiles to draw in time.");
}

static void guard_fill_path(fz_context *ctx, fz_device *dev, const fz_path *path, int even_odd, fz_matrix ctm, fz_colorspace *cs,
                            const float *color, float alpha, fz_color_params cp) {
    guard_check(ctx, dev);
    FORWARD(dev, fill_path, path, even_odd, ctm, cs, color, alpha, cp);
}

static void guard_stroke_path(fz_context *ctx, fz_device *dev, const fz_path *path, const fz_stroke_state *stroke, fz_matrix ctm,
                              fz_colorspace *cs, const float *color, float alpha, fz_color_params cp) {
    guard_check(ctx, dev);
    FORWARD(dev, stroke_path, path, stroke, ctm, cs, color, alpha, cp);
}

static void guard_clip_path(fz_context *ctx, fz_device *dev, const fz_path *path, int even_odd, fz_matrix ctm, fz_rect scissor) {
    guard_check(ctx, dev);
    fz_clip_path(ctx, TARGET(dev), path, even_odd, ctm, scissor);
}

static void guard_clip_stroke_path(fz_context *ctx, fz_device *dev, const fz_path *path, const fz_stroke_state *stroke, fz_matrix ctm,
                                   fz_rect scissor) {
    guard_check(ctx, dev);
    fz_clip_stroke_path(ctx, TARGET(dev), path, stroke, ctm, scissor);
}

static void guard_fill_text(fz_context *ctx, fz_device *dev, const fz_text *text, fz_matrix ctm, fz_colorspace *cs, const float *color,
                            float alpha, fz_color_params cp) {
    guard_check(ctx, dev);
    FORWARD(dev, fill_text, text, ctm, cs, color, alpha, cp);
}

static void guard_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *text, const fz_stroke_state *stroke, fz_matrix ctm,
                              fz_colorspace *cs, const float *color, float alpha, fz_color_params cp) {
    guard_check(ctx, dev);
    FORWARD(dev, stroke_text, text, stroke, ctm, cs, color, alpha, cp);
}

static void guard_clip_text(fz_context *ctx, fz_device *dev, const fz_text *text, fz_matrix ctm, fz_rect scissor) {
    guard_check(ctx, dev);
    fz_clip_text(ctx, TARGET(dev), text, ctm, scissor);
}

static void guard_clip_stroke_text(fz_context *ctx, fz_device *dev, const fz_text *text, const fz_stroke_state *stroke, fz_matrix ctm,
                                   fz_rect scissor) {
    guard_check(ctx, dev);
    fz_clip_stroke_text(ctx, TARGET(dev), text, stroke, ctm, scissor);
}

static void guard_ignore_text(fz_context *ctx, fz_device *dev, const fz_text *text, fz_matrix ctm) {
    guard_check(ctx, dev);
    FORWARD(dev, ignore_text, text, ctm);
}

static void guard_fill_shade(fz_context *ctx, fz_device *dev, fz_shade *shade, fz_matrix ctm, float alpha, fz_color_params cp) {
    inkv_watch(ctx, ((inkv_guard *)dev)->cookie, FZ_ERROR_ABORT); // a shading's mesh is drawn in one call
    FORWARD(dev, fill_shade, shade, ctm, alpha, cp);
}

static void guard_fill_image(fz_context *ctx, fz_device *dev, fz_image *image, fz_matrix ctm, float alpha, fz_color_params cp) {
    guard_picture(ctx, dev, image);
    FORWARD(dev, fill_image, image, ctm, alpha, cp);
}

static void guard_fill_image_mask(fz_context *ctx, fz_device *dev, fz_image *image, fz_matrix ctm, fz_colorspace *cs, const float *color,
                                  float alpha, fz_color_params cp) {
    guard_picture(ctx, dev, image);
    FORWARD(dev, fill_image_mask, image, ctm, cs, color, alpha, cp);
}

static void guard_clip_image_mask(fz_context *ctx, fz_device *dev, fz_image *image, fz_matrix ctm, fz_rect scissor) {
    guard_picture(ctx, dev, image);
    fz_clip_image_mask(ctx, TARGET(dev), image, ctm, scissor);
}

static void guard_pop_clip(fz_context *ctx, fz_device *dev) { fz_pop_clip(ctx, TARGET(dev)); }

static void guard_begin_mask(fz_context *ctx, fz_device *dev, fz_rect area, int luminosity, fz_colorspace *cs, const float *bc,
                             fz_color_params cp) {
    guard_check(ctx, dev);
    fz_begin_mask(ctx, TARGET(dev), area, luminosity, cs, bc, cp);
}

static void guard_end_mask(fz_context *ctx, fz_device *dev, fz_function *fn) { fz_end_mask_tr(ctx, TARGET(dev), fn); }

static void guard_begin_group(fz_context *ctx, fz_device *dev, fz_rect area, fz_colorspace *cs, int isolated, int knockout, int blendmode,
                              float alpha) {
    guard_check(ctx, dev);
    fz_begin_group(ctx, TARGET(dev), area, cs, isolated, knockout, blendmode, alpha);
}

static void guard_end_group(fz_context *ctx, fz_device *dev) { fz_end_group(ctx, TARGET(dev)); }

static int guard_begin_tile(fz_context *ctx, fz_device *dev, fz_rect area, fz_rect view, float xstep, float ystep, fz_matrix ctm, int id) {
    guard_tiles(ctx, dev, area, view, xstep, ystep, ctm);
    return fz_begin_tile_id(ctx, TARGET(dev), area, view, xstep, ystep, ctm, id);
}

static void guard_end_tile(fz_context *ctx, fz_device *dev) { fz_end_tile(ctx, TARGET(dev)); }

static void guard_render_flags(fz_context *ctx, fz_device *dev, int set, int clear) { fz_render_flags(ctx, TARGET(dev), set, clear); }

static void guard_set_default_colorspaces(fz_context *ctx, fz_device *dev, fz_default_colorspaces *cs) {
    fz_set_default_colorspaces(ctx, TARGET(dev), cs);
}

static void guard_begin_layer(fz_context *ctx, fz_device *dev, const char *name) { fz_begin_layer(ctx, TARGET(dev), name); }
static void guard_end_layer(fz_context *ctx, fz_device *dev) { fz_end_layer(ctx, TARGET(dev)); }

static void guard_begin_structure(fz_context *ctx, fz_device *dev, fz_structure standard, const char *raw, int idx) {
    fz_begin_structure(ctx, TARGET(dev), standard, raw, idx);
}

static void guard_end_structure(fz_context *ctx, fz_device *dev) { fz_end_structure(ctx, TARGET(dev)); }

static void guard_begin_metatext(fz_context *ctx, fz_device *dev, fz_metatext meta, const char *text) {
    fz_begin_metatext(ctx, TARGET(dev), meta, text);
}

static void guard_end_metatext(fz_context *ctx, fz_device *dev) { fz_end_metatext(ctx, TARGET(dev)); }

/// A guard in front of `target` (which the caller closes and drops after the guard). Throws.
static fz_device *inkv_new_guard(fz_context *ctx, fz_device *target, inkv_cookie *cookie) {
    inkv_guard *g = fz_new_derived_device(ctx, inkv_guard);
    g->target = target;
    g->cookie = cookie;
    // What the interpreter asks of its device (skip pictures, no caching) is the target's.
    g->super.hints = target->hints;
    g->super.flags = target->flags;
    g->super.fill_path = guard_fill_path;
    g->super.stroke_path = guard_stroke_path;
    g->super.clip_path = guard_clip_path;
    g->super.clip_stroke_path = guard_clip_stroke_path;
    g->super.fill_text = guard_fill_text;
    g->super.stroke_text = guard_stroke_text;
    g->super.clip_text = guard_clip_text;
    g->super.clip_stroke_text = guard_clip_stroke_text;
    g->super.ignore_text = guard_ignore_text;
    g->super.fill_shade = guard_fill_shade;
    g->super.fill_image = guard_fill_image;
    g->super.fill_image_mask = guard_fill_image_mask;
    g->super.clip_image_mask = guard_clip_image_mask;
    g->super.pop_clip = guard_pop_clip;
    g->super.begin_mask = guard_begin_mask;
    g->super.end_mask = guard_end_mask;
    g->super.begin_group = guard_begin_group;
    g->super.end_group = guard_end_group;
    g->super.begin_tile = guard_begin_tile;
    g->super.end_tile = guard_end_tile;
    g->super.render_flags = guard_render_flags;
    g->super.set_default_colorspaces = guard_set_default_colorspaces;
    g->super.begin_layer = guard_begin_layer;
    g->super.end_layer = guard_end_layer;
    g->super.begin_structure = guard_begin_structure;
    g->super.end_structure = guard_end_structure;
    g->super.begin_metatext = guard_begin_metatext;
    g->super.end_metatext = guard_end_metatext;
    return &g->super;
}

/// A guard in front of a draw device made with `transform` over `pix` (NULL without a cookie: nothing to guard). Throws.
static fz_device *inkv_new_draw_guard(fz_context *ctx, fz_device *draw, inkv_cookie *cookie, fz_matrix transform, fz_pixmap *pix) {
    if (!cookie) return NULL;
    inkv_guard *g = (inkv_guard *)inkv_new_guard(ctx, draw, cookie);
    g->drawing = 1;
    g->transform = transform;
    g->pixels = fz_pixmap_bbox(ctx, pix);
    return &g->super;
}

// ---- A page's streams, before it is read ----

/// Filters that make more bytes than they read; two in a row make at most a megabyte of each byte (Flate's 1,032 to 1,
/// twice), which the document's stream sees within milliseconds. No real file chains more.
static const char *const inkv_inflating[] = {
    "FlateDecode", "Fl", "LZWDecode", "LZW", "RunLengthDecode", "RL", "BrotliDecode", "Br", "CCITTFaxDecode", "CCF",
    "JBIG2Decode", "DCTDecode", "DCT", "JPXDecode",
};
#define INKV_MAX_INFLATING 2

static int inkv_inflates(fz_context *ctx, pdf_obj *filter) {
    int many = pdf_is_array(ctx, filter), n = many ? pdf_array_len(ctx, filter) : 1, count = 0;
    for (int i = 0; i < n; i++) {
        const char *name = pdf_to_name(ctx, many ? pdf_array_get(ctx, filter, i) : filter);
        for (size_t k = 0; k < sizeof(inkv_inflating) / sizeof(*inkv_inflating); k++)
            if (!strcmp(name, inkv_inflating[k])) {
                count++;
                break;
            }
    }
    return count;
}

/// Keys that lead away from what drawing the page reads: up the page tree, to other pages, actions, the outline.
static int inkv_away(fz_context *ctx, pdf_obj *key) {
    static pdf_obj *const keys[] = {
        PDF_NAME(Parent), PDF_NAME(P), PDF_NAME(Dest), PDF_NAME(A), PDF_NAME(AA), PDF_NAME(Next), PDF_NAME(Prev),
        PDF_NAME(First), PDF_NAME(Last), PDF_NAME(Popup), PDF_NAME(IRT), PDF_NAME(Thumb), PDF_NAME(B), PDF_NAME(PieceInfo),
        PDF_NAME(Metadata),
    };
    for (size_t k = 0; k < sizeof(keys) / sizeof(*keys); k++)
        if (pdf_name_eq(ctx, key, keys[k])) return 1;
    return 0;
}

/// Refuses the page (INKV_STOP_FILTERS) when a stream it reaches (its content, forms, patterns, pictures, fonts,
/// shadings, its annotations' appearances) is decompressed more than twice in a row: the inner filters' bytes never
/// reach the document's stream, so nothing would bound them. Each object once; the call's time and Cancel looked at as
/// it goes. Throws.
static void inkv_check_streams(fz_context *ctx, fz_page *page, inkv_cookie *c) {
    pdf_page *pp = c ? pdf_page_from_fz_page(ctx, page) : NULL;
    if (!pp) return;
    pdf_obj **stack = NULL, *at = NULL;
    unsigned char *seen = NULL;
    int top = 0, capacity = 64, bits = 0;
    unsigned steps = 0;
    fz_var(stack);
    fz_var(at);
    fz_var(seen);
    fz_var(top);
    fz_var(capacity);
    fz_var(bits);
    fz_try(ctx) {
        pdf_obj *root = pdf_resolve_indirect(ctx, pp->obj);
        stack = fz_malloc_array(ctx, capacity, pdf_obj *);
        stack[top++] = pdf_keep_obj(ctx, pp->obj);
        while (top > 0) {
            at = stack[--top];
            if ((++steps & 255) == 0) inkv_watch(ctx, c, FZ_ERROR_ABORT);
            fz_try(ctx) {
                pdf_obj *o = at;
                int visit = 1;
                if (pdf_is_indirect(ctx, at)) {
                    int num = pdf_to_num(ctx, at);
                    if (num >= bits) {
                        // Objects an edit or a repair added are past the length the walk started with.
                        int more = num + 1 > 2 * bits ? num + 1 : 2 * bits;
                        size_t had = bits ? (size_t)bits / 8 + 1 : 0, need = (size_t)more / 8 + 1;
                        seen = fz_realloc(ctx, seen, need);
                        memset(seen + had, 0, need - had);
                        bits = more;
                    }
                    if (num <= 0 || (seen[num >> 3] & (1 << (num & 7)))) visit = 0;
                    else {
                        seen[num >> 3] |= (unsigned char)(1 << (num & 7));
                        if (pdf_is_stream(ctx, at) && inkv_inflates(ctx, pdf_dict_get(ctx, at, PDF_NAME(Filter))) > INKV_MAX_INFLATING)
                            inkv_stop(ctx, c, INKV_STOP_FILTERS, FZ_ERROR_ABORT, "A stream on the page is decompressed too many times.");
                        o = pdf_resolve_indirect(ctx, at);
                    }
                }
                if (visit && pdf_is_dict(ctx, o)) {
                    pdf_obj *type = pdf_dict_get(ctx, o, PDF_NAME(Type));
                    if (o != root && (pdf_name_eq(ctx, type, PDF_NAME(Page)) || pdf_name_eq(ctx, type, PDF_NAME(Pages)))) visit = 0;
                }
                int dict = visit && pdf_is_dict(ctx, o), n = !visit ? 0 : dict ? pdf_dict_len(ctx, o) : pdf_is_array(ctx, o) ? pdf_array_len(ctx, o) : 0;
                for (int i = 0; i < n; i++) {
                    if (dict && inkv_away(ctx, pdf_dict_get_key(ctx, o, i))) continue;
                    pdf_obj *v = dict ? pdf_dict_get_val(ctx, o, i) : pdf_array_get(ctx, o, i);
                    // Numbers, names and strings lead nowhere.
                    if (!pdf_is_indirect(ctx, v) && !pdf_is_dict(ctx, v) && !pdf_is_array(ctx, v)) continue;
                    if (top == capacity) {
                        stack = fz_realloc_array(ctx, stack, capacity * 2, pdf_obj *);
                        capacity *= 2;
                    }
                    stack[top++] = pdf_keep_obj(ctx, v);
                }
            }
            fz_always(ctx) {
                pdf_drop_obj(ctx, at);
                at = NULL;
            }
            fz_catch(ctx) {
                // A damaged object is MuPDF's to report when it draws; the walk goes on. A stop doesn't.
                if (atomic_load(&c->stopped) || fz_caught(ctx) == FZ_ERROR_TRYLATER || fz_caught(ctx) == FZ_ERROR_SYSTEM)
                    fz_rethrow(ctx);
                fz_ignore_error(ctx);
            }
        }
    }
    fz_always(ctx) {
        while (top > 0) pdf_drop_obj(ctx, stack[--top]);
        fz_free(ctx, stack);
        fz_free(ctx, seen);
    }
    fz_catch(ctx) fz_rethrow(ctx);
}

/// An open document and the pages it keeps loaded: at most `capacity`, the least recently used freed first (with
/// their display lists), so memory stays bounded however far a long document is scrolled.
struct inkv_doc {
    fz_document *doc;
    inkv_source *src; // the stream it reads, NULL for a document made here
    int count;
    int capacity;
    int loaded;
    fz_page **pages;
    fz_display_list **lists;
    unsigned *used;
    unsigned clock;
};

/// Starts a call that reads a page's content with `c` (NULL: unbounded): its first part's time from now.
static void inkv_begin(inkv_doc *d, inkv_cookie *c) {
    if (c) {
        atomic_store(&c->stopped, atomic_load(&c->cancelled) ? INKV_STOP_CANCELLED : 0);
        // A cookie used again starts unaborted, unless it was cancelled: a cancel racing this clear sets it again
        // after (it sets `cancelled` first, then the abort; this clears, then looks at `cancelled` again).
        if (!atomic_load(&c->cancelled)) {
            __atomic_store_n(&c->cookie.abort, 0, __ATOMIC_SEQ_CST);
            if (atomic_load(&c->cancelled)) inkv_set_abort(c);
        } else {
            inkv_set_abort(c);
        }
        c->deadline = c->seconds > 0 ? inkv_cpu() + c->seconds : 0;
    }
    if (d->src) {
        d->src->active = c;
        d->src->chunk = 16;
        d->src->last = inkv_cpu();
    }
}

/// The call's next part (drawing what was read) gets a budget of its own.
static void inkv_next_part(inkv_cookie *c) {
    if (c && c->seconds > 0) c->deadline = inkv_cpu() + c->seconds;
}

static void inkv_end(inkv_doc *d) {
    if (d->src) {
        d->src->active = NULL;
        d->src->chunk = INKV_CHUNK_MAX;
    }
}

/// Whether the call that used `c` was stopped (its time, a picture, Cancel).
static int inkv_halted(inkv_cookie *c) { return c && (atomic_load(&c->stopped) || atomic_load(&c->cancelled)); }

/// Whether MuPDF was asked to stop (the cookie's own flag, which a cancel sets from another thread).
static int inkv_aborted(inkv_cookie *c) { return c && (inkv_halted(c) || __atomic_load_n(&c->cookie.abort, __ATOMIC_SEQ_CST)); }

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

/// A display list of the page (its own content only, or with its annotations and widgets), read under the cookie's
/// bounds through a guard. A list whose reading was stopped is dropped, never kept: it throws. Throws.
static fz_display_list *inkv_new_list(fz_context *ctx, fz_page *page, int contents_only, inkv_cookie *c) {
    fz_display_list *list = fz_new_display_list(ctx, fz_bound_page(ctx, page));
    fz_device *dev = NULL, *guard = NULL;
    fz_var(dev);
    fz_var(guard);
    fz_try(ctx) {
        inkv_check_streams(ctx, page, c);
        dev = fz_new_list_device(ctx, list);
        guard = c ? inkv_new_guard(ctx, dev, c) : NULL;
        fz_device *run = guard ? guard : dev;
        fz_cookie *cookie = c ? &c->cookie : NULL;
        if (contents_only) fz_run_page_contents(ctx, page, run, fz_identity, cookie);
        else fz_run_page(ctx, page, run, fz_identity, cookie);
        if (guard) fz_close_device(ctx, guard);
        fz_close_device(ctx, dev);
        if (inkv_halted(c)) fz_throw(ctx, FZ_ERROR_ABORT, "The page's reading was stopped.");
    }
    fz_always(ctx) {
        fz_drop_device(ctx, guard);
        fz_drop_device(ctx, dev);
    }
    fz_catch(ctx) {
        fz_drop_display_list(ctx, list);
        fz_rethrow(ctx);
    }
    return list;
}

/// The page's display list (made once while the page stays loaded, unless its reading was stopped). Throws.
static fz_display_list *inkv_list(fz_context *ctx, inkv_doc *d, int i, inkv_cookie *c) {
    fz_page *page = inkv_page(ctx, d, i);
    if (!d->lists[i]) d->lists[i] = inkv_new_list(ctx, page, 0, c);
    return d->lists[i];
}

static inkv_doc *inkv_open(fz_context *ctx, fz_stream *stream, inkv_source *src, const char *magic, int cache, char *err) {
    inkv_doc *result = NULL;
    fz_var(result);
    fz_try(ctx) {
        result = fz_malloc_struct(ctx, inkv_doc);
        result->doc = fz_open_document_with_stream(ctx, magic, stream);
        result->src = src; // kept alive by the document, which holds the stream
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

/// A document of type `magic` from memory: the bytes copied, or with `shared` read in place (the caller keeps them alive
/// and unchanged until the document is dropped).
static inkv_doc *inkv_open_bytes(fz_context *ctx, const uint8_t *data, size_t length, const char *magic, int cache, int shared, char *err) {
    fz_buffer *buffer = NULL;
    fz_stream *stream = NULL;
    inkv_source *src = NULL;
    inkv_doc *result = NULL;
    fz_var(buffer);
    fz_var(stream);
    fz_var(src);
    fz_try(ctx) {
        const unsigned char *bytes = data;
        if (!shared) {
            buffer = fz_new_buffer_from_copied_data(ctx, data, length);
            unsigned char *copy = NULL;
            fz_buffer_storage(ctx, buffer, &copy);
            bytes = copy;
        }
        stream = inkv_new_source(ctx, bytes, (int64_t)length, buffer, -1, &src);
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, buffer);
        inkv_error(ctx, err);
        return NULL;
    }
    result = inkv_open(ctx, stream, src, magic, cache, err);
    fz_drop_stream(ctx, stream);
    fz_drop_buffer(ctx, buffer);
    return result;
}

inkv_doc *inkv_open_pdf(void *vctx, const uint8_t *data, size_t length, int cache, char *err) {
    return inkv_open_bytes((fz_context *)vctx, data, length, "application/pdf", cache, 0, err);
}

inkv_doc *inkv_open_pdf_shared(void *vctx, const uint8_t *data, size_t length, int cache, char *err) {
    return inkv_open_bytes((fz_context *)vctx, data, length, "application/pdf", cache, 1, err);
}

inkv_doc *inkv_open_path(void *vctx, const char *path, int cache, char *err) {
    fz_context *ctx = vctx;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) {
        if (err) snprintf(err, INKV_ERR_SIZE, "cannot open %s: %s", path, strerror(errno));
        if (fd >= 0) close(fd);
        return NULL;
    }
    fz_stream *stream = NULL;
    inkv_source *src = NULL;
    fz_var(stream);
    fz_var(src);
    fz_try(ctx) stream = inkv_new_source(ctx, NULL, (int64_t)st.st_size, NULL, fd, &src); // closes fd if it throws
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return NULL;
    }
    // The file's name tells MuPDF its type, as fz_open_document did.
    inkv_doc *result = inkv_open(ctx, stream, src, path, cache, err);
    fz_drop_stream(ctx, stream);
    return result;
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
    if (!c) return;
    atomic_store(&c->cancelled, 1);
    inkv_set_abort(c);
}
void inkv_drop_cookie(inkv_cookie *c) { free(c); }

void inkv_cookie_limit(inkv_cookie *c, double seconds, double max_pixels) {
    if (!c) return;
    c->seconds = seconds > 0 ? seconds : 0;
    c->max_pixels = max_pixels > 0 ? max_pixels : 0;
}

int inkv_cookie_stopped(inkv_cookie *c) {
    if (!c) return 0;
    int stopped = atomic_load(&c->stopped);
    return stopped ? stopped : atomic_load(&c->cancelled) ? INKV_STOP_CANCELLED : 0;
}

void inkv_test_slow_reads(inkv_doc *d, double seconds) {
    if (d && d->src) d->src->delay = seconds > 0 ? seconds : 0;
}

static int render_rgb(void *vctx, inkv_doc *d, int index, int contents_only, float scale, float x0, float y0, float x1, float y1,
                      inkv_cookie *cookie, uint8_t **pixels, int *width, int *height, char *err) {
    fz_context *ctx = vctx;
    fz_pixmap *pix = NULL;
    fz_device *dev = NULL, *guard = NULL;
    fz_display_list *own = NULL;
    int aborted = 0;
    fz_var(pix);
    fz_var(dev);
    fz_var(guard);
    fz_var(own);
    fz_var(aborted);
    *pixels = NULL;
    inkv_begin(d, cookie);
    fz_try(ctx) {
        // The page's own content only (no annotations): a list of its own, not the cached one.
        fz_display_list *list = contents_only ? (own = inkv_new_list(ctx, inkv_page(ctx, d, index), 1, cookie))
                                              : inkv_list(ctx, d, index, cookie);
        inkv_next_part(cookie);
        fz_matrix ctm = fz_scale(scale, scale);
        fz_rect area = fz_make_rect(x0, y0, x1, y1);
        fz_irect box = fz_round_rect(fz_transform_rect(area, ctm));
        pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), box, NULL, 0);
        fz_clear_pixmap_with_value(ctx, pix, 255);
        dev = fz_new_draw_device(ctx, fz_identity, pix);
        guard = inkv_new_draw_guard(ctx, dev, cookie, fz_identity, pix);
        fz_run_display_list(ctx, list, guard ? guard : dev, ctm, fz_transform_rect(area, ctm), cookie ? &cookie->cookie : NULL);
        if (guard) fz_close_device(ctx, guard);
        fz_close_device(ctx, dev);
        if (inkv_aborted(cookie)) {
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
        fz_drop_device(ctx, guard);
        fz_drop_device(ctx, dev);
        fz_drop_pixmap(ctx, pix);
        fz_drop_display_list(ctx, own);
        inkv_end(d);
    }
    fz_catch(ctx) {
        if (inkv_aborted(cookie)) {
            fz_ignore_error(ctx);
            return 2;
        }
        inkv_error(ctx, err);
        return 0;
    }
    return aborted ? 2 : 1;
}

int inkv_render_rgb(void *vctx, inkv_doc *d, int index, float scale, float x0, float y0, float x1, float y1,
                    inkv_cookie *cookie, uint8_t **pixels, int *width, int *height, char *err) {
    return render_rgb(vctx, d, index, 0, scale, x0, y0, x1, y1, cookie, pixels, width, height, err);
}

int inkv_render_rgb_contents(void *vctx, inkv_doc *d, int index, float scale, float x0, float y0, float x1, float y1,
                             inkv_cookie *cookie, uint8_t **pixels, int *width, int *height, char *err) {
    return render_rgb(vctx, d, index, 1, scale, x0, y0, x1, y1, cookie, pixels, width, height, err);
}

int inkv_save_image(void *vctx, inkv_doc *d, int index, float scale, const char *path, int jpeg, inkv_cookie *cookie, char *err) {
    fz_context *ctx = vctx;
    fz_pixmap *pix = NULL;
    fz_device *dev = NULL, *guard = NULL;
    fz_var(pix);
    fz_var(dev);
    fz_var(guard);
    inkv_begin(d, cookie);
    fz_try(ctx) {
        fz_display_list *list = inkv_list(ctx, d, index, cookie);
        inkv_next_part(cookie);
        // fz_new_pixmap_from_display_list, with the cookie: no file is written for a drawing that was stopped.
        fz_matrix ctm = fz_scale(scale, scale);
        pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), fz_round_rect(fz_transform_rect(fz_bound_display_list(ctx, list), ctm)), NULL, 0);
        fz_clear_pixmap_with_value(ctx, pix, 255);
        dev = fz_new_draw_device(ctx, ctm, pix);
        guard = inkv_new_draw_guard(ctx, dev, cookie, ctm, pix);
        fz_run_display_list(ctx, list, guard ? guard : dev, fz_identity, fz_infinite_rect, cookie ? &cookie->cookie : NULL);
        if (guard) fz_close_device(ctx, guard);
        fz_close_device(ctx, dev);
        if (inkv_aborted(cookie)) fz_throw(ctx, FZ_ERROR_ABORT, "The page's drawing was stopped.");
        if (jpeg) fz_save_pixmap_as_jpeg(ctx, pix, path, 90);
        else fz_save_pixmap_as_png(ctx, pix, path);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, guard);
        fz_drop_device(ctx, dev);
        fz_drop_pixmap(ctx, pix);
        inkv_end(d);
    }
    fz_catch(ctx) {
        if (inkv_halted(cookie)) {
            fz_ignore_error(ctx);
            return 2;
        }
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

/// Runs the page (its own content, or with its annotations and widgets) into a text device, under the cookie's
/// bounds; throws when the reading was stopped. Throws.
static void inkv_run_text(fz_context *ctx, fz_page *page, int annotations, fz_device *dev, inkv_cookie *c) {
    inkv_check_streams(ctx, page, c);
    fz_device *guard = c ? inkv_new_guard(ctx, dev, c) : NULL;
    fz_try(ctx) {
        fz_device *run = guard ? guard : dev;
        fz_cookie *cookie = c ? &c->cookie : NULL;
        if (annotations) fz_run_page(ctx, page, run, fz_identity, cookie);
        else fz_run_page_contents(ctx, page, run, fz_identity, cookie);
        if (guard) fz_close_device(ctx, guard);
        if (inkv_halted(c)) fz_throw(ctx, FZ_ERROR_ABORT, "The page's reading was stopped.");
    }
    fz_always(ctx) fz_drop_device(ctx, guard);
    fz_catch(ctx) fz_rethrow(ctx);
}

static int page_chars(void *vctx, inkv_doc *d, int index, int annotations, inkv_line **lines, int *line_count,
                      inkv_char **chars, int *char_count, inkv_cookie *cookie, char *err) {
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
    inkv_begin(d, cookie);
    fz_try(ctx) {
        fz_page *page = inkv_page(ctx, d, index);
        fz_stext_options options = { 0 };
        text = fz_new_stext_page(ctx, fz_bound_page(ctx, page));
        dev = fz_new_stext_device(ctx, text, &options);
        inkv_run_text(ctx, page, annotations, dev, cookie);
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
                    cs[ci].flags = c->flags;
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
        inkv_end(d);
    }
    fz_catch(ctx) {
        free(ls);
        free(cs);
        if (inkv_halted(cookie)) {
            fz_ignore_error(ctx);
            return 2;
        }
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_page_chars(void *ctx, inkv_doc *d, int index, inkv_line **lines, int *line_count, inkv_char **chars,
                    int *char_count, inkv_cookie *cookie, char *err) {
    return page_chars(ctx, d, index, 0, lines, line_count, chars, char_count, cookie, err);
}

int inkv_page_chars_annots(void *ctx, inkv_doc *d, int index, inkv_line **lines, int *line_count, inkv_char **chars,
                           int *char_count, inkv_cookie *cookie, char *err) {
    return page_chars(ctx, d, index, 1, lines, line_count, chars, char_count, cookie, err);
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
        // MuPDF copies the file it opened into the output before the update (a buffer can't be read back, so it can't
        // see that the original is there already): keep only the update, after the original bytes as given.
        buffer = fz_new_buffer(ctx, 64 * 1024);
        output = fz_new_output_with_buffer(ctx, buffer);
        pdf_write_document(ctx, pdf, output, &opts);
        fz_close_output(ctx, output);
        unsigned char *bytes = NULL;
        size_t n = fz_buffer_storage(ctx, buffer, &bytes);
        size_t base = pdf->file_size > 0 && (size_t)pdf->file_size <= n ? (size_t)pdf->file_size : 0;
        size_t update = n - base;
        uint8_t *copy = malloc(original_length + update + 1);
        if (!copy) fz_throw(ctx, FZ_ERROR_SYSTEM, "There isn't enough memory to write the PDF.");
        if (original_length) memcpy(copy, original, original_length);
        if (update) memcpy(copy + original_length, bytes + base, update);
        *out = copy;
        *length = original_length + update;
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
    return inkv_open_bytes((fz_context *)vctx, data, length, magic, 4, 0, err);
}

int inkv_render_rgba(void *vctx, inkv_doc *d, int index, float scale, uint8_t **pixels, int *width, int *height, char *err) {
    fz_context *ctx = vctx;
    fz_pixmap *pix = NULL;
    fz_var(pix);
    *pixels = NULL;
    fz_try(ctx) {
        pix = fz_new_pixmap_from_display_list(ctx, inkv_list(ctx, d, index, NULL), fz_scale(scale, scale), fz_device_rgb(ctx), 1);
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

// ---- Export (D5c) ----

/// A picture's pixels encoded as PNG or JPEG into e->data; left NULL when MuPDF can't (the caller renders it instead).
static void inkv_encode_image(fz_context *ctx, fz_image *image, int jpeg, inkv_eimage *e) {
    fz_pixmap *pix = NULL, *rgb = NULL;
    fz_buffer *buf = NULL;
    fz_var(pix);
    fz_var(rgb);
    fz_var(buf);
    fz_try(ctx) {
        pix = fz_get_pixmap_from_image(ctx, image, NULL, NULL, NULL, NULL);
        fz_colorspace *cs = fz_pixmap_colorspace(ctx, pix);
        int plain = cs && (fz_colorspace_is_rgb(ctx, cs) || fz_colorspace_is_gray(ctx, cs));
        // PNG takes gray or RGB (with alpha); JPEG takes no alpha.
        if (!plain || (jpeg && fz_pixmap_alpha(ctx, pix)))
            rgb = fz_convert_pixmap(ctx, pix, fz_device_rgb(ctx), NULL, NULL, fz_default_color_params, jpeg ? 0 : 1);
        fz_pixmap *use = rgb ? rgb : pix;
        buf = jpeg ? fz_new_buffer_from_pixmap_as_jpeg(ctx, use, fz_default_color_params, 85, 0)
                   : fz_new_buffer_from_pixmap_as_png(ctx, use, fz_default_color_params);
        unsigned char *bytes = NULL;
        size_t n = fz_buffer_storage(ctx, buf, &bytes);
        uint8_t *copy = malloc(n ? n : 1);
        if (!copy) fz_throw(ctx, FZ_ERROR_SYSTEM, "There is not enough memory for the picture.");
        memcpy(copy, bytes, n);
        e->data = copy;
        e->length = n;
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buf);
        fz_drop_pixmap(ctx, rgb);
        fz_drop_pixmap(ctx, pix);
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        e->data = NULL;
        e->length = 0;
    }
}

void inkv_free_export(inkv_export *e) {
    if (!e) return;
    for (int i = 0; i < e->font_count; i++) free(e->fonts[i].name);
    for (int i = 0; i < e->image_count; i++) free(e->images[i].data);
    free(e->lines);
    free(e->chars);
    free(e->fonts);
    free(e->images);
    free(e->vectors);
    memset(e, 0, sizeof(*e));
}

/// The index of `font` among the export's fonts, added (with its name and flags) when new. Throws.
static int inkv_export_font(fz_context *ctx, inkv_export *out, fz_font ***seen, int *capacity, fz_font *font) {
    for (int k = out->font_count - 1; k >= 0; k--)
        if ((*seen)[k] == font) return k;
    if (out->font_count == *capacity) {
        int grown = *capacity * 2;
        inkv_efont *fonts = realloc(out->fonts, sizeof(inkv_efont) * (size_t)grown);
        if (fonts) out->fonts = fonts;
        fz_font **more = realloc(*seen, sizeof(fz_font *) * (size_t)grown);
        if (more) *seen = more;
        if (!fonts || !more) fz_throw(ctx, FZ_ERROR_SYSTEM, "There is not enough memory for the page's fonts.");
        *capacity = grown;
    }
    int k = out->font_count++;
    (*seen)[k] = font;
    inkv_efont *f = &out->fonts[k];
    f->name = inkv_strdup(fz_font_name(ctx, font));
    f->bold = fz_font_is_bold(ctx, font);
    f->italic = fz_font_is_italic(ctx, font);
    f->serif = fz_font_is_serif(ctx, font);
    f->mono = fz_font_is_monospaced(ctx, font);
    return k;
}

int inkv_export_page(void *vctx, inkv_doc *d, int index, int images, long long jpeg_above, inkv_export *out, inkv_cookie *cookie, char *err) {
    fz_context *ctx = vctx;
    fz_stext_page *text = NULL;
    fz_device *dev = NULL;
    fz_font **seen = NULL;
    fz_var(text);
    fz_var(dev);
    fz_var(seen);
    memset(out, 0, sizeof(*out));
    inkv_begin(d, cookie);
    fz_try(ctx) {
        fz_page *page = inkv_page(ctx, d, index);
        fz_stext_options options = { 0 };
        options.flags = FZ_STEXT_COLLECT_VECTORS | (images ? FZ_STEXT_PRESERVE_IMAGES : 0);
        text = fz_new_stext_page(ctx, fz_bound_page(ctx, page));
        dev = fz_new_stext_device(ctx, text, &options);
        inkv_run_text(ctx, page, 1, dev, cookie);
        fz_close_device(ctx, dev);
        inkv_next_part(cookie); // the pictures' encoding below
        int nl = 0, nc = 0, ni = 0, nv = 0;
        for (fz_stext_block *b = text->first_block; b; b = b->next) {
            if (b->type == FZ_STEXT_BLOCK_TEXT) {
                for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
                    nl++;
                    for (fz_stext_char *c = l->first_char; c; c = c->next) nc++;
                }
            } else if (b->type == FZ_STEXT_BLOCK_IMAGE) {
                ni++;
            } else if (b->type == FZ_STEXT_BLOCK_VECTOR) {
                nv++;
            }
        }
        int capacity = 16;
        out->lines = malloc(sizeof(inkv_line) * (size_t)(nl ? nl : 1));
        out->chars = malloc(sizeof(inkv_echar) * (size_t)(nc ? nc : 1));
        out->images = calloc((size_t)(ni ? ni : 1), sizeof(inkv_eimage));
        out->vectors = malloc(sizeof(inkv_evector) * (size_t)(nv ? nv : 1));
        out->fonts = calloc((size_t)capacity, sizeof(inkv_efont));
        seen = calloc((size_t)capacity, sizeof(fz_font *));
        if (!out->lines || !out->chars || !out->images || !out->vectors || !out->fonts || !seen)
            fz_throw(ctx, FZ_ERROR_SYSTEM, "There is not enough memory for the page's text.");
        int li = 0, ci = 0, last = -1;
        for (fz_stext_block *b = text->first_block; b; b = b->next) {
            if (b->type == FZ_STEXT_BLOCK_TEXT) {
                for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
                    out->lines[li].first = ci;
                    out->lines[li].dx = l->dir.x;
                    out->lines[li].dy = l->dir.y;
                    for (fz_stext_char *c = l->first_char; c; c = c->next) {
                        fz_rect r = fz_rect_from_quad(c->quad);
                        inkv_echar *e = &out->chars[ci++];
                        e->c = c->c;
                        e->x0 = r.x0;
                        e->y0 = r.y0;
                        e->x1 = r.x1;
                        e->y1 = r.y1;
                        e->size = c->size;
                        e->argb = c->argb;
                        e->font = -1;
                        out->char_count = ci;
                        if (!c->font) continue;
                        // Characters mostly share the font of the one before.
                        if (last < 0 || seen[last] != c->font) last = inkv_export_font(ctx, out, &seen, &capacity, c->font);
                        e->font = last;
                    }
                    out->lines[li].count = ci - out->lines[li].first;
                    out->line_count = ++li;
                }
            } else if (b->type == FZ_STEXT_BLOCK_IMAGE) {
                inkv_eimage *e = &out->images[out->image_count++];
                fz_image *img = b->u.i.image;
                e->x0 = b->bbox.x0;
                e->y0 = b->bbox.y0;
                e->x1 = b->bbox.x1;
                e->y1 = b->bbox.y1;
                e->width = img ? img->w : 0;
                e->height = img ? img->h : 0;
                e->jpeg = (long long)e->width * e->height > jpeg_above;
                if (images == 1 && img && e->width > 0 && e->height > 0) {
                    // Each picture is decoded whole (a second for the largest allowed): Cancel, closing and the
                    // encoding's time are looked at between them.
                    inkv_watch(ctx, cookie, FZ_ERROR_ABORT);
                    inkv_encode_image(ctx, img, e->jpeg, e);
                } /* 2: where it is, without its pixels */
            } else if (b->type == FZ_STEXT_BLOCK_VECTOR) {
                inkv_evector *e = &out->vectors[out->vector_count++];
                e->x0 = b->bbox.x0;
                e->y0 = b->bbox.y0;
                e->x1 = b->bbox.x1;
                e->y1 = b->bbox.y1;
                e->stroked = b->u.v.stroked != 0;
                e->argb = b->u.v.argb;
            }
        }
    }
    fz_always(ctx) {
        free(seen);
        fz_drop_device(ctx, dev);
        fz_drop_stext_page(ctx, text);
        inkv_end(d);
    }
    fz_catch(ctx) {
        inkv_free_export(out);
        if (inkv_halted(cookie)) {
            fz_ignore_error(ctx);
            return 2;
        }
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_render_region_rgba(void *vctx, inkv_doc *d, int index, float scale, float x0, float y0, float x1, float y1,
                            uint8_t **pixels, int *width, int *height, inkv_cookie *cookie, char *err) {
    fz_context *ctx = vctx;
    fz_pixmap *pix = NULL;
    fz_device *dev = NULL, *guard = NULL;
    fz_var(pix);
    fz_var(dev);
    fz_var(guard);
    *pixels = NULL;
    inkv_begin(d, cookie);
    fz_try(ctx) {
        fz_display_list *list = inkv_list(ctx, d, index, cookie);
        inkv_next_part(cookie);
        fz_matrix ctm = fz_scale(scale, scale);
        fz_rect area = fz_transform_rect(fz_make_rect(x0, y0, x1, y1), ctm);
        pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), fz_round_rect(area), NULL, 1);
        fz_clear_pixmap(ctx, pix);
        dev = fz_new_draw_device(ctx, fz_identity, pix);
        guard = inkv_new_draw_guard(ctx, dev, cookie, fz_identity, pix);
        fz_run_display_list(ctx, list, guard ? guard : dev, ctm, area, cookie ? &cookie->cookie : NULL);
        if (guard) fz_close_device(ctx, guard);
        fz_close_device(ctx, dev);
        if (inkv_aborted(cookie)) fz_throw(ctx, FZ_ERROR_ABORT, "The page's drawing was stopped.");
        int w = fz_pixmap_width(ctx, pix), h = fz_pixmap_height(ctx, pix);
        size_t stride = (size_t)fz_pixmap_stride(ctx, pix), row = (size_t)w * 4;
        uint8_t *px = malloc(row * (size_t)(h > 0 ? h : 1));
        if (!px) fz_throw(ctx, FZ_ERROR_SYSTEM, "There is not enough memory for the picture's pixels.");
        const uint8_t *src = fz_pixmap_samples(ctx, pix);
        for (int y = 0; y < h; y++) memcpy(px + row * (size_t)y, src + stride * (size_t)y, row);
        // Premultiplied by alpha in MuPDF; straight for PNG.
        for (size_t k = 0; k < row * (size_t)h; k += 4) {
            unsigned a = px[k + 3];
            if (a == 0 || a == 255) continue;
            for (int c = 0; c < 3; c++) {
                unsigned v = px[k + c] * 255u / a;
                px[k + c] = (uint8_t)(v > 255 ? 255 : v);
            }
        }
        *pixels = px;
        *width = w;
        *height = h;
    }
    fz_always(ctx) {
        fz_drop_device(ctx, guard);
        fz_drop_device(ctx, dev);
        fz_drop_pixmap(ctx, pix);
        inkv_end(d);
    }
    fz_catch(ctx) {
        if (inkv_halted(cookie)) {
            fz_ignore_error(ctx);
            return 2;
        }
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_pdf_version(void *vctx, inkv_doc *d) {
    fz_context *ctx = vctx;
    int version = 0;
    fz_try(ctx) version = pdf_version(ctx, inkv_pdf(ctx, d));
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        return 0;
    }
    return version;
}

int inkv_obj_location(void *vctx, inkv_doc *d, int num, int64_t *offset) {
    fz_context *ctx = vctx;
    int where = 0;
    fz_try(ctx) {
        pdf_document *pdf = inkv_pdf(ctx, d);
        pdf_xref_entry *x = num > 0 && num < pdf_xref_len(ctx, pdf) ? pdf_get_xref_entry_no_change(ctx, pdf, num) : NULL;
        if (x && x->type == 'n') where = 1;
        if (x && x->type == 'o') where = 2;
        if (x) *offset = x->ofs;
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        return 0;
    }
    return where;
}

int inkv_obj_replace(void *vctx, inkv_doc *d, int num, const uint8_t *text, size_t length, int encrypted, char *err) {
    fz_context *ctx = vctx;
    fz_stream *stm = NULL;
    fz_buffer *data = NULL;
    pdf_obj *obj = NULL, *ref = NULL;
    pdf_lexbuf buf;
    pdf_lexbuf_init(ctx, &buf, PDF_LEXBUF_SMALL);
    fz_var(stm);
    fz_var(data);
    fz_var(obj);
    fz_var(ref);
    fz_try(ctx) {
        pdf_document *pdf = inkv_pdf(ctx, d);
        pdf_xref_entry *x = pdf_get_xref_entry_no_change(ctx, pdf, num);
        int gen = x ? x->gen : 0;
        stm = fz_open_memory(ctx, text, length);
        obj = pdf_parse_stm_obj(ctx, pdf, stm, &buf);
        if (encrypted && pdf->crypt) pdf_crypt_obj(ctx, pdf->crypt, obj, num, gen);
        // The new entry has no stream: its data goes along as it is stored (the same /Filter).
        if (pdf_obj_num_is_stream(ctx, pdf, num)) data = pdf_load_raw_stream_number(ctx, pdf, num);
        pdf_update_object(ctx, pdf, num, obj);
        if (data) {
            ref = pdf_new_indirect(ctx, pdf, num, 0);
            pdf_update_stream(ctx, pdf, ref, data, 1);
        }
    }
    fz_always(ctx) {
        pdf_drop_obj(ctx, ref);
        pdf_drop_obj(ctx, obj);
        fz_drop_buffer(ctx, data);
        fz_drop_stream(ctx, stm);
        pdf_lexbuf_fin(ctx, &buf);
    }
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}

int inkv_set_pdf_version(void *vctx, inkv_doc *d, int version, char *err) {
    fz_context *ctx = vctx;
    fz_try(ctx) inkv_pdf(ctx, d)->version = version;
    fz_catch(ctx) {
        inkv_error(ctx, err);
        return 0;
    }
    return 1;
}
