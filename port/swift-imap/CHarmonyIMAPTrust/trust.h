#ifndef THUNDERBIRD_IMAP_TRUST_H
#define THUNDERBIRD_IMAP_TRUST_H
#include <stddef.h>
#include <stdint.h>
typedef struct ThunderbirdIMAPTrust ThunderbirdIMAPTrust;
ThunderbirdIMAPTrust *tb_imap_trust_open(const char *host);
size_t tb_imap_trust_count(const ThunderbirdIMAPTrust *trust);
const char *tb_imap_trust_certificate(const ThunderbirdIMAPTrust *trust, size_t index);
const char *tb_imap_trust_pins(const ThunderbirdIMAPTrust *trust);
void tb_imap_trust_close(ThunderbirdIMAPTrust *trust);
int tb_imap_sha256(const uint8_t *bytes, size_t length, uint8_t *digest);
#endif
