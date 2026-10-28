#ifndef INKV_ICU_REGEX_H
#define INKV_ICU_REGEX_H

#include <stdint.h>

/// Compiles a regular expression with ICU (the engine behind NSRegularExpression) only to say what is wrong with it,
/// which NSRegularExpression doesn't: 0 when it compiles; else ICU's error code, with the UTF-16 offset where ICU
/// stopped in `offset` and the error's name (such as "U_REGEX_MISMATCHED_PAREN") copied into `name` (`size` bytes).
/// `flags`: ICU's (2 = case insensitive).
int inkv_regex_check(const uint16_t *pattern, int32_t length, uint32_t flags, int32_t *offset, char *name, int size);

#endif
