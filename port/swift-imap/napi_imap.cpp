// Isolated app diagnostic; all network and Swift work runs off the ArkUI thread.
#include <napi/native_api.h>
#include <hilog/log.h>
#include <memory>
#include <string>
#include <vector>
#include <thread>
#include <fcntl.h>
#include <unistd.h>
extern "C" int thunderbird_imap_probe(const char *, const char *);
struct Work {
    napi_async_work work;
    napi_deferred deferred;
    std::string mode;
    int result = 1;
};
static void Execute(napi_env, void *data) {
    auto *work = static_cast<Work *>(data);
    // Kill this disposable diagnostic process if native teardown ever deadlocks.
    alarm(15);
    work->result = thunderbird_imap_probe(work->mode.c_str(), "/data/storage/el2/base/files/native-network-ca/root.crt");
    alarm(0);
}
static void Complete(napi_env env, napi_status status, void *data) {
    std::unique_ptr<Work> work(static_cast<Work *>(data));
    napi_value value;
    napi_create_int32(env, status == napi_ok ? work->result : -1, &value);
    napi_resolve_deferred(env, work->deferred, value);
    napi_delete_async_work(env, work->work);
}
static napi_value Request(napi_env env, napi_callback_info info) {
    size_t argc = 1, length = 0;
    napi_value argv[1], name, promise;
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 1 ||
        napi_get_value_string_utf8(env, argv[0], nullptr, 0, &length) != napi_ok || length > 32) {
        napi_throw_type_error(env, nullptr, "Expected a fixture mode"); return nullptr;
    }
    std::vector<char> bytes(length + 1);
    napi_get_value_string_utf8(env, argv[0], bytes.data(), bytes.size(), &length);
    auto work = std::make_unique<Work>();
    work->mode.assign(bytes.data(), length);
    napi_create_string_utf8(env, "SwiftIMAPProbe", NAPI_AUTO_LENGTH, &name);
    if (napi_create_async_work(env, nullptr, name, Execute, Complete, work.get(), &work->work) != napi_ok) return nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) { napi_delete_async_work(env, work->work); return nullptr; }
    if (napi_queue_async_work(env, work->work) != napi_ok) {
        napi_delete_async_work(env, work->work);
        napi_throw_error(env, nullptr, "Cannot queue IMAP probe"); return nullptr;
    }
    work.release(); return promise;
}
static napi_value Init(napi_env env, napi_value exports) {
    int diagnostics[2];
    if (pipe2(diagnostics, O_CLOEXEC) == 0) {
        dup2(diagnostics[1], STDERR_FILENO); dup2(diagnostics[1], STDOUT_FILENO); close(diagnostics[1]);
        setvbuf(stdout, nullptr, _IONBF, 0);
        std::thread([fd = diagnostics[0]] {
            char buffer[1024]; ssize_t count;
            while ((count = read(fd, buffer, sizeof(buffer))) > 0)
                OH_LOG_Print(LOG_APP, LOG_INFO, 1, "IMAPProbe", "%{public}.*s", int(count), buffer);
            close(fd);
        }).detach();
    }
    napi_property_descriptor property = {"request", nullptr, Request, nullptr, nullptr, nullptr, napi_default, nullptr};
    napi_define_properties(env, exports, 1, &property); return exports;
}
static napi_module module = {1, 0, nullptr, Init, "imaptest", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterIMAPTest() { napi_module_register(&module); }
