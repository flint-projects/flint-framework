#ifndef FLINT_BCRYPT_ABI_H
#define FLINT_BCRYPT_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* bcrypt over the pinned crypt_blowfish provider (Openwall crypt_blowfish 1.3). Results use
 * flint_security_status: FLINT_SEC_UNSUPPORTED when the provider is absent, FLINT_SEC_ARGUMENT when the
 * provider refuses the input (bad setting, cost out of range, output too small). */

/* Hash `key` (its first 72 bytes, as bcrypt does) with `setting`: "$2a$NN$" and 22 salt characters, or a whole
 * stored hash to verify against. Writes a NUL-terminated 60-character hash into `output` (capacity >= 61). */
int flint_bcrypt_hash(const uint8_t *key, size_t key_length, const char *setting, size_t setting_length,
                      char *output, size_t capacity);

/* A setting for `minor` ('a', 'b' or 'y') at `cost` (4..31) from 16 random bytes; NUL-terminated, capacity >= 30. */
int flint_bcrypt_setting(char minor, unsigned cost, const uint8_t random[16], char *output, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
