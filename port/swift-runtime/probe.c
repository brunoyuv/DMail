#include <stdint.h>
#include <stdio.h>

extern int32_t swift_harmony_runtime_probe(void);

int main(void) {
    int32_t result = swift_harmony_runtime_probe();
    if (result != 0) {
        fprintf(stderr, "SWIFT_OHOS_RUNTIME_FAILED:%d\n", (int)result);
        return (int)result;
    }
    puts("SWIFT_OHOS_RUNTIME_OK");
    return 0;
}
