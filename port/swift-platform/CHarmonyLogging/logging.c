// MPL-2.0: https://mozilla.org/MPL/2.0/
#include "logging.h"
#include <hilog/log.h>
void thunderbird_hilog_info(const char *category, const char *message) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 1, "Thunderbird", "%{public}s: %{public}s", category, message);
}
void thunderbird_hilog_debug(const char *category, const char *message) {
    OH_LOG_Print(LOG_APP, LOG_DEBUG, 1, "Thunderbird", "%{public}s: %{public}s", category, message);
}
void thunderbird_hilog_error(const char *category, const char *message) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 1, "Thunderbird", "%{public}s: %{public}s", category, message);
}
