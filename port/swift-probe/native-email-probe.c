#include <stdint.h>
#include <stdio.h>

extern int32_t thunderbird_email_address_probe(void);
extern int32_t thunderbird_email_address_validate(const char *input);
int main(void) {
    int32_t result = thunderbird_email_address_probe();
    if (result) {
        fprintf(stderr, "THUNDERBIRD_NATIVE_EMAIL_ADDRESS_FAILED:%d\n", (int)result);
        return (int)result;
    }
    if (thunderbird_email_address_validate("Reader <reader@example.com>") != 1 ||
        thunderbird_email_address_validate("invalid") != 0 ||
        thunderbird_email_address_validate(NULL) != 0) {
        fputs("THUNDERBIRD_NATIVE_C_ABI_FAILED\n", stderr);
        return 20;
    }
    puts("THUNDERBIRD_NATIVE_EMAIL_ADDRESS_OK");
    return 0;
}
