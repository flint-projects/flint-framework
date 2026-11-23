#include "flint_bcrypt.h"
#include "flint_security.h"

#include <string.h>

#ifdef FLINT_HAS_CRYPT_BLOWFISH
#include <crypt_blowfish.h>

/* Clears a stack copy of the key so it does not outlive the call. */
static void flint_bcrypt_wipe(char *bytes, size_t length)
{
    volatile char *cursor = bytes;
    while (length--)
        *cursor++ = 0;
}
#endif

int flint_bcrypt_hash(const uint8_t *key, size_t key_length, const char *setting, size_t setting_length,
                      char *output, size_t capacity)
{
#ifdef FLINT_HAS_CRYPT_BLOWFISH
    char key_text[73];
    char setting_text[64];
    const char *result;
    size_t used;
    if ((key == NULL && key_length != 0) || setting == NULL || output == NULL || capacity < 61 || capacity > 4096
        || setting_length >= sizeof setting_text)
        return FLINT_SEC_ARGUMENT;
    /* bcrypt reads at most 72 key bytes; a NUL ends the key, as the C string crypt_blowfish takes. */
    used = key_length > 72 ? 72 : key_length;
    if (used != 0)
        memcpy(key_text, key, used);
    key_text[used] = '\0';
    memcpy(setting_text, setting, setting_length);
    setting_text[setting_length] = '\0';
    result = _crypt_blowfish_rn(key_text, setting_text, output, (int)capacity);
    flint_bcrypt_wipe(key_text, sizeof key_text);
    if (result == NULL)
    {
        output[0] = '\0';
        return FLINT_SEC_ARGUMENT;
    }
    return FLINT_SEC_OK;
#else
    (void)key;
    (void)key_length;
    (void)setting;
    (void)setting_length;
    (void)output;
    (void)capacity;
    return FLINT_SEC_UNSUPPORTED;
#endif
}

int flint_bcrypt_setting(char minor, unsigned cost, const uint8_t random[16], char *output, size_t capacity)
{
#ifdef FLINT_HAS_CRYPT_BLOWFISH
    char prefix[5] = {'$', '2', 'a', '$', '\0'};
    if (random == NULL || output == NULL || capacity < 30 || capacity > 4096
        || (minor != 'a' && minor != 'b' && minor != 'y'))
        return FLINT_SEC_ARGUMENT;
    prefix[2] = minor;
    if (_crypt_gensalt_blowfish_rn(prefix, cost, (const char *)random, 16, output, (int)capacity) == NULL)
    {
        output[0] = '\0';
        return FLINT_SEC_ARGUMENT;
    }
    return FLINT_SEC_OK;
#else
    (void)minor;
    (void)cost;
    (void)random;
    (void)output;
    (void)capacity;
    return FLINT_SEC_UNSUPPORTED;
#endif
}
