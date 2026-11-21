#include "flint_rpc.h"

#include <string.h>

#ifdef FLINT_HAS_OPENSSL
#include <openssl/evp.h>
#include <openssl/rand.h>

int flint_rpc_websocket_key(char *output, size_t capacity) {
    unsigned char nonce[16], encoded[25];
    if (!output || capacity < 24)
        return -1;
    if (RAND_bytes(nonce, sizeof(nonce)) != 1 || EVP_EncodeBlock(encoded, nonce, sizeof(nonce)) != 24)
        return -2;
    memcpy(output, encoded, 24);
    return 0;
}

int flint_rpc_websocket_accept(const char *key, size_t key_length, char *output, size_t capacity) {
    static const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    char digest_input[24 + sizeof(guid) - 1];
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned char encoded[29];
    unsigned length;
    if (key == NULL || key_length != 24 || output == NULL || capacity < 28)
        return -1;
    if (key[22] != '=' || key[23] != '=' || key[21] == '\0' || strchr("AQgw", key[21]) == NULL)
        return -1;
    for (size_t index = 0; index < 21; ++index) {
        if (key[index] == '\0' || strchr(alphabet, key[index]) == NULL)
            return -1;
    }
    memcpy(digest_input, key, 24);
    memcpy(digest_input + 24, guid, sizeof(guid) - 1);
    if (EVP_Digest(digest_input, sizeof(digest_input), digest, &length, EVP_sha1(), NULL) != 1 ||
            length != 20 || EVP_EncodeBlock(encoded, digest, (int)length) != 28)
        return -2;
    memcpy(output, encoded, 28);
    return 0;
}
#endif
