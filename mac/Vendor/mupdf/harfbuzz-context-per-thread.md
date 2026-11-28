# To report upstream: HarfBuzz's context is one global across contexts that don't share locks

MuPDF 1.25.2, `source/fitz/harfbuzz.c`. HarfBuzz's allocator hooks (`fz_hb_malloc` and the rest) find their context in
`static fz_context *fz_hb_secret`, which `fz_hb_lock` sets and `fz_hb_unlock` clears. The lock taken is the calling
context's `FZ_LOCK_FREETYPE`, so it excludes only clones of one context. Two contexts made by separate `fz_new_context`
calls (each with its own locks, or none), each used on its own thread as the threading docs allow, can both be inside
`fz_hb_lock`: the first `fz_hb_unlock` sets the global to NULL while the other still shapes, and its next HarfBuzz
allocation calls `fz_malloc_no_throw(NULL, …)` (SIGSEGV; the `assert` is compiled out in release), or allocates
through the other context's allocator, which may be dropped by then.

Reproduction: two threads, each with its own `fz_new_context`, opening and laying out an FB2 or EPUB (html-layout.c),
or updating a FreeText annotation's rich-text appearance (`fz_new_story` in pdf-appearance.c), in a loop. Inkvolt's
test: `OtherFormatsTests.fictionBooksLaidOutOnSeveralThreadsAtOnce` (48 FB2 conversions on `concurrentPerform`).

Suggested fix (Inkvolt's patch, `patches/harfbuzz-context-per-thread.patch`): `static _Thread_local fz_context
*fz_hb_secret`. Each thread sets and clears its own, under the same lock as before; HarfBuzz frees within
`fz_hb_lock` too (`hb_buffer_destroy`, the font's shaper data), so a pointer is freed through the context of the
thread holding the lock, which shares its allocator with the one that allocated it (a clone, or the same context).
