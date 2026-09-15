// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
#include <curl/curl.h>
#include <network/netstack/net_ssl/net_ssl_c.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int append(char **target, const char *value, const char *separator) {
    size_t old = *target ? strlen(*target) : 0;
    size_t extra = strlen(value) + (old ? strlen(separator) : 0);
    if (old + extra > 4 * 1024 * 1024) return 0;
    char *next = realloc(*target, old + extra + 1);
    if (!next) return 0;
    *target = next;
    if (!old) next[0] = 0;
    else strcat(next, separator);
    strcat(next, value);
    return 1;
}

// Called for every URL selected by FoundationNetworking, including redirects.
// Trust material comes from HarmonyOS; libcurl still verifies the peer and host.
CURLcode ThunderbirdConfigureTrust(CURL *handle, const char *url) {
    CURLU *parsed = curl_url();
    char *host = NULL, *scheme = NULL, *paths = NULL, *pem = NULL;
    NetStack_Certificates certificates = {0};
    NetStack_CertificatePinning pins = {0};
    CURLcode result = CURLE_URL_MALFORMAT;
    if (!parsed) return CURLE_OUT_OF_MEMORY;
    if (curl_url_set(parsed, CURLUPART_URL, url, 0) ||
        curl_url_get(parsed, CURLUPART_HOST, &host, 0) ||
        curl_url_get(parsed, CURLUPART_SCHEME, &scheme, 0)) goto finish;
    if (!strcmp(scheme, "http") || !strcmp(scheme, "ws")) {
        bool allowed = false;
        result = OH_Netstack_IsCleartextPermittedByHostName(host, &allowed) == 0 && allowed
            ? CURLE_OK : CURLE_REMOTE_ACCESS_DENIED;
        goto finish;
    }
    if (strcmp(scheme, "https") && strcmp(scheme, "wss")) {
        result = CURLE_OK;
        goto finish;
    }
    result = CURLE_SSL_CACERT_BADFILE;
    if (OH_NetStack_GetCertificatesForHostName(host, &certificates) != 0 ||
        OH_NetStack_GetPinSetForHostName(host, &pins) != 0) goto finish;
    struct stat info;
    const char *system = "/etc/security/certificates";
    if (stat(system, &info) != 0 || !S_ISDIR(info.st_mode) || !append(&paths, system, ":")) goto finish;
    for (size_t i = 0; i < certificates.length; ++i) {
        const char *cert = certificates.content[i];
        if (!cert) goto finish;
        if (!strncmp(cert, "-----BEGIN CERTIFICATE-----", 27)) {
            if (!append(&pem, cert, "\n")) goto finish;
        } else {
            // OpenHarmony's implementation returns rehashed directories.
            if (cert[0] != '/' || strchr(cert, ':') || stat(cert, &info) != 0 ||
                !S_ISDIR(info.st_mode) || !append(&paths, cert, ":")) goto finish;
        }
    }
    if (pins.publicKeyHash && (pins.kind != PUBLIC_KEY || pins.hashAlgorithm != SHA_256)) goto finish;
    struct curl_blob blob = {pem, pem ? strlen(pem) : 0, CURL_BLOB_COPY};
#define SET(option, value) do { result = curl_easy_setopt(handle, option, value); if (result) goto finish; } while (0)
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_CAINFO, NULL);
    SET(CURLOPT_CAPATH, paths);
    SET(CURLOPT_CAINFO_BLOB, pem ? &blob : NULL);
    SET(CURLOPT_PINNEDPUBLICKEY, pins.publicKeyHash);
#undef SET
finish:
    OH_Netstack_DestroyCertificatesContent(&certificates);
    free(pins.publicKeyHash);
    free(paths);
    free(pem);
    curl_free(host);
    curl_free(scheme);
    curl_url_cleanup(parsed);
    return result;
}
