#include "crypto.h"
#include <openssl/sha.h>
int tb_autoconfig_sha256(const uint8_t *bytes, size_t count, uint8_t *digest) {
    return SHA256(bytes, count, digest) != NULL;
}
