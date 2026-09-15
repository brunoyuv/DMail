#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <semaphore.h>
#include <time.h>

extern void swift_harmony_concurrency_probe(void (*completed)(int32_t));
static sem_t completion;
static int32_t result = -1;
static void completed(int32_t value) {
    result = value;
    sem_post(&completion);
}

int main(void) {
    if (sem_init(&completion, 0, 0)) return 10;
    struct timespec deadline;
    if (clock_gettime(CLOCK_REALTIME, &deadline)) return 11;
    deadline.tv_sec += 15;
    swift_harmony_concurrency_probe(completed);
    int wait_result;
    do {
        wait_result = sem_timedwait(&completion, &deadline);
    } while (wait_result && errno == EINTR);
    if (wait_result) {
        perror("SWIFT_OHOS_CONCURRENCY_TIMEOUT");
        return 12;
    }
    sem_destroy(&completion);
    if (result) {
        fprintf(stderr, "SWIFT_OHOS_CONCURRENCY_FAILED:%d\n", (int)result);
        return (int)result;
    }
    puts("SWIFT_OHOS_CONCURRENCY_OK");
    return 0;
}
