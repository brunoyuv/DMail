#ifndef TB_AUTOCONFIG_CRYPTO_H
#define TB_AUTOCONFIG_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
int tb_autoconfig_sha256(const uint8_t *bytes, size_t count, uint8_t *digest);
#endif
