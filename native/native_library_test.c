#include <llhttp.h>
#include <zlib.h>
#include <string.h>
#include "flint_abi_probe.h"
static int completed;
static int on_complete(llhttp_t *parser) { (void)parser; ++completed; return 0; }
int flint_native_smoke(void) {
    llhttp_settings_t settings;
    llhttp_t parser;
    llhttp_settings_init(&settings); settings.on_message_complete = on_complete;
    llhttp_init(&parser, HTTP_REQUEST, &settings);
    const char message[] = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    completed = 0;
    if (llhttp_execute(&parser, message, sizeof(message)-1) != HPE_OK || completed != 1) return 1;
    const unsigned char original[] = "Flint pinned C ABI smoke";
    unsigned char compressed[128], decoded[128];
    uLongf compressed_length = sizeof(compressed), decoded_length = sizeof(decoded);
    if (compress2(compressed, &compressed_length, original, sizeof(original), 1) != Z_OK) return 2;
    if (uncompress(decoded, &decoded_length, compressed, compressed_length) != Z_OK) return 3;
    if (decoded_length != sizeof(original) || memcmp(decoded, original, sizeof(original))) return 4;
    flint_abi_info info;
    if (flint_abi_probe(&info, sizeof(info))) return 5;
    if (info.llhttp_bytes != sizeof(llhttp_t) || info.pointer_bytes != sizeof(void*)) return 6;
    return 0;
}
#ifdef FLINT_SMOKE_MAIN
int main(void) { return flint_native_smoke(); }
#endif
