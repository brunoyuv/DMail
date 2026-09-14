// MPL-2.0: https://mozilla.org/MPL/2.0/
// Host-test sink only; HarmonyOS builds use CHarmonyLogging/logging.c and HiLog.
#include "logging.h"
#include <stdio.h>
void thunderbird_hilog_info(const char *category, const char *message) {
    fprintf(stderr, "%s: %s\n", category, message);
}
void thunderbird_hilog_debug(const char *category, const char *message) {
    thunderbird_hilog_info(category, message);
}
void thunderbird_hilog_error(const char *category, const char *message) {
    thunderbird_hilog_info(category, message);
}
