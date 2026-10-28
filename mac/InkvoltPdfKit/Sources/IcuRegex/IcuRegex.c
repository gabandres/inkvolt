// NSRegularExpression reports a bad pattern without saying where or why; ICU's own regex API does (a UParseError). The
// functions are exported by the system's libicucore (Apple builds it without ICU's version suffixes) but its headers
// aren't in the SDK, so the few used here are declared with ICU's documented signatures (unicode/uregex.h, utypes.h).

#include "IcuRegex.h"
#include <string.h>

typedef uint16_t UChar;
typedef int UErrorCode;
typedef struct URegularExpression URegularExpression;

enum { U_PARSE_CONTEXT_LEN = 16 };

typedef struct UParseError {
    int32_t line;
    int32_t offset;
    UChar preContext[U_PARSE_CONTEXT_LEN];
    UChar postContext[U_PARSE_CONTEXT_LEN];
} UParseError;

extern URegularExpression *uregex_open(const UChar *pattern, int32_t patternLength, uint32_t flags, UParseError *pe,
                                       UErrorCode *status);
extern void uregex_close(URegularExpression *regexp);
extern const char *u_errorName(UErrorCode code);

int inkv_regex_check(const uint16_t *pattern, int32_t length, uint32_t flags, int32_t *offset, char *name, int size) {
    UParseError pe;
    memset(&pe, 0, sizeof pe);
    UErrorCode status = 0;
    URegularExpression *re = uregex_open(pattern, length, flags, &pe, &status);
    if (re) uregex_close(re);
    if (status <= 0) return 0; // U_ZERO_ERROR, or a warning
    *offset = pe.offset;
    const char *n = u_errorName(status);
    if (name && size > 0) {
        strncpy(name, n ? n : "", (size_t)size - 1);
        name[size - 1] = 0;
    }
    return status;
}
