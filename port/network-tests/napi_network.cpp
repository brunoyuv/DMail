// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
#include <napi/native_api.h>
#include <memory>
#include <string>
#include <vector>
#include <fcntl.h>
#include <unistd.h>
#include <thread>
#include <hilog/log.h>
extern "C" char *thunderbird_network_probe(const char *input);
extern "C" void thunderbird_network_probe_free(char *output);
struct Work {
    napi_async_work work;
    napi_deferred deferred;
    std::string input;
    char *output = nullptr;
    ~Work() { thunderbird_network_probe_free(output); }
};
static void Execute(napi_env, void *data) {
    auto *work = static_cast<Work *>(data);
    work->output = thunderbird_network_probe(work->input.c_str());
}
static void Complete(napi_env env, napi_status status, void *data) {
    std::unique_ptr<Work> work(static_cast<Work *>(data));
    napi_value value;
    if (status == napi_ok && work->output) {
        napi_create_string_utf8(env, work->output, NAPI_AUTO_LENGTH, &value);
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message;
        napi_create_string_utf8(env, "Network probe failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &value);
        napi_reject_deferred(env, work->deferred, value);
    }
    napi_delete_async_work(env, work->work);
}
static napi_value Request(napi_env env, napi_callback_info info) {
    size_t argc = 1, length = 0;
    napi_value argv[1], name, promise;
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 1 ||
        napi_get_value_string_utf8(env, argv[0], nullptr, 0, &length) != napi_ok || length > 4096) {
        napi_throw_type_error(env, nullptr, "Expected a small JSON request"); return nullptr;
    }
    std::vector<char> bytes(length + 1);
    napi_get_value_string_utf8(env, argv[0], bytes.data(), bytes.size(), &length);
    auto work = std::make_unique<Work>();
    work->input.assign(bytes.data(), length);
    napi_create_string_utf8(env, "SwiftNetworkProbe", NAPI_AUTO_LENGTH, &name);
    if (napi_create_async_work(env, nullptr, name, Execute, Complete, work.get(), &work->work) != napi_ok) return nullptr;
    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok) { napi_delete_async_work(env, work->work); return nullptr; }
    if (napi_queue_async_work(env, work->work) != napi_ok) {
        napi_delete_async_work(env, work->work);
        napi_throw_error(env, nullptr, "Cannot queue probe"); return nullptr;
    }
    work.release(); return promise;
}
static napi_value Init(napi_env env, napi_value exports) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 1, "NetworkProbe", "Diagnostics installed");
    // Route this disposable app's runtime diagnostics into the collected hilog.
    int diagnostics[2];
    if (pipe2(diagnostics, O_CLOEXEC) == 0) {
        dup2(diagnostics[1], STDERR_FILENO);
        close(diagnostics[1]);
        std::thread([fd = diagnostics[0]] {
            char buffer[1024];
            ssize_t count;
            while ((count = read(fd, buffer, sizeof(buffer))) > 0) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, 1, "NetworkProbe", "%{public}.*s", int(count), buffer);
            }
            close(fd);
        }).detach();
    }
    napi_property_descriptor property = {"request", nullptr, Request, nullptr, nullptr, nullptr, napi_default, nullptr};
    napi_define_properties(env, exports, 1, &property); return exports;
}
static napi_module module = {1, 0, nullptr, Init, "networktest", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterNetworkTest() { napi_module_register(&module); }
