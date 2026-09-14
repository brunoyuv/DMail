// Application-specific certificate roots and pins are supplied by HarmonyOS.
#include "trust.h"
#include <stdbool.h>
#include <network/netstack/net_ssl/net_ssl_c.h>
#include <openssl/sha.h>
#include <stdlib.h>
#include <string.h>
struct ThunderbirdIMAPTrust {
    NetStack_Certificates certificates;
    NetStack_CertificatePinning pins;
};
void tb_imap_trust_close(ThunderbirdIMAPTrust *trust) {
    if (!trust) return;
    OH_Netstack_DestroyCertificatesContent(&trust->certificates);
    free(trust->pins.publicKeyHash);
    free(trust);
}
ThunderbirdIMAPTrust *tb_imap_trust_open(const char *host) {
    if (!host || strlen(host) > 253) return NULL;
    ThunderbirdIMAPTrust *trust = calloc(1, sizeof(*trust));
    if (!trust) return NULL;
    if (OH_NetStack_GetCertificatesForHostName(host, &trust->certificates) != 0 ||
        OH_NetStack_GetPinSetForHostName(host, &trust->pins) != 0 ||
        trust->certificates.length > 512 ||
        (trust->certificates.length && !trust->certificates.content)) goto fail;
    size_t bytes = 0;
    for (size_t i = 0; i < trust->certificates.length; i++) {
        const char *value = trust->certificates.content[i];
        if (!value || (bytes += strlen(value)) > 4 * 1024 * 1024) goto fail;
    }
    if (trust->pins.publicKeyHash && (strlen(trust->pins.publicKeyHash) > 16384 ||
        trust->pins.kind != PUBLIC_KEY || trust->pins.hashAlgorithm != SHA_256)) goto fail;
    return trust;
fail:
    tb_imap_trust_close(trust); return NULL;
}
size_t tb_imap_trust_count(const ThunderbirdIMAPTrust *trust) { return trust->certificates.length; }
const char *tb_imap_trust_certificate(const ThunderbirdIMAPTrust *trust, size_t index) {
    return index < trust->certificates.length ? trust->certificates.content[index] : NULL;
}
const char *tb_imap_trust_pins(const ThunderbirdIMAPTrust *trust) { return trust->pins.publicKeyHash; }
int tb_imap_sha256(const uint8_t *bytes, size_t length, uint8_t *digest) {
    return length <= 65536 && SHA256(bytes, length, digest) != NULL;
}
