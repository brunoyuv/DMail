#include <napi/native_api.h>
#include <cstdint>
#include <string>
#include <vector>
#include <memory>

extern "C" int32_t thunderbird_email_address_validate(const char *input);
extern "C" char *thunderbird_mime_request(int32_t operation, const char *input);
extern "C" char *thunderbird_jmap_account_request(const char *input);
extern "C" char *thunderbird_imap_account_request(const char *input);
extern "C" char *thunderbird_smtp_account_request(const char *input);
extern "C" char *thunderbird_discovery_request(const char *input);
extern "C" char *thunderbird_oauth_request(const char *input);
extern "C" void thunderbird_string_free(char *value);

struct NativeWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int32_t operation = 0;
    std::string input;
    char *output = nullptr;
    ~NativeWork() { thunderbird_string_free(output); }
};

static void ExecuteNative(napi_env, void *data) {
    auto *request = static_cast<NativeWork *>(data);
    request->output = request->operation == 7 ? thunderbird_oauth_request(request->input.c_str()) :
        request->operation == 6 ? thunderbird_discovery_request(request->input.c_str()) :
        request->operation == 5 ? thunderbird_smtp_account_request(request->input.c_str()) :
        request->operation == 4 ? thunderbird_imap_account_request(request->input.c_str()) :
        request->operation == 3 ? thunderbird_jmap_account_request(request->input.c_str()) :
        thunderbird_mime_request(request->operation, request->input.c_str());
}

static void CompleteNative(napi_env env, napi_status status, void *data) {
    std::unique_ptr<NativeWork> request(static_cast<NativeWork *>(data));
    napi_value value;
    if (status == napi_ok && request->output &&
        napi_create_string_utf8(env, request->output, NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, request->deferred, value);
    } else {
        napi_value message;
        napi_create_string_utf8(env, "Native core operation failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &value);
        napi_reject_deferred(env, request->deferred, value);
    }
    napi_delete_async_work(env, request->work);
}

static napi_value QueueNative(napi_env env, napi_callback_info info, int32_t accountOperation) {
    const bool account = accountOperation != 0;
    size_t argc = account ? 1 : 2;
    napi_value argv[2];
    napi_valuetype operationType, inputType;
    auto request = std::make_unique<NativeWork>();
    const size_t inputIndex = account ? 0 : 1;
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != (account ? 1 : 2) ||
        napi_typeof(env, argv[inputIndex], &inputType) != napi_ok || inputType != napi_string ||
        (!account && (napi_typeof(env, argv[0], &operationType) != napi_ok || operationType != napi_number ||
        napi_get_value_int32(env, argv[0], &request->operation) != napi_ok || request->operation < 0 || request->operation > 2))) {
        napi_throw_type_error(env, nullptr, "Invalid native request arguments");
        return nullptr;
    }
    if (account) request->operation = accountOperation;
    size_t length = 0;
    if (napi_get_value_string_utf8(env, argv[inputIndex], nullptr, 0, &length) != napi_ok) return nullptr;
    if (length > ((accountOperation == 7 || accountOperation == 4) ? 128 * 1024 :
        accountOperation == 5 ? 16 * 1024 * 1024 : account ? 4 * 1024 * 1024 : 16 * 1024 * 1024)) {
        napi_throw_range_error(env, "NATIVE_LIMIT", "Native request exceeds input limit");
        return nullptr;
    }
    std::vector<char> buffer(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, argv[inputIndex], buffer.data(), buffer.size(), &copied) != napi_ok) return nullptr;
    request->input.assign(buffer.data(), copied);
    if (request->input.find('\0') != std::string::npos) {
        napi_throw_type_error(env, "NATIVE_INPUT", "Native input contains NUL");
        return nullptr;
    }
    napi_value promise, name;
    if (napi_create_string_utf8(env, account ? "ThunderbirdJMAPAccount" : "ThunderbirdMIME", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_async_work(env, nullptr, name, ExecuteNative, CompleteNative, request.get(), &request->work) != napi_ok) {
        napi_throw_error(env, nullptr, "Cannot create native core work");
        return nullptr;
    }
    if (napi_create_promise(env, &request->deferred, &promise) != napi_ok) {
        napi_delete_async_work(env, request->work);
        return nullptr;
    }
    if (napi_queue_async_work(env, request->work) != napi_ok) {
        napi_value message, error;
        napi_create_string_utf8(env, "Cannot queue native core work", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &error);
        napi_reject_deferred(env, request->deferred, error);
        napi_delete_async_work(env, request->work);
        return promise;
    }
    request.release(); // CompleteNative owns the request until the promise settles.
    return promise;
}

static napi_value MimeRequest(napi_env env, napi_callback_info info) { return QueueNative(env, info, 0); }
static napi_value JmapAccountRequest(napi_env env, napi_callback_info info) { return QueueNative(env, info, 3); }
static napi_value SmtpAccountRequest(napi_env env, napi_callback_info info) { return QueueNative(env, info, 5); }
static napi_value ImapAccountRequest(napi_env env, napi_callback_info info) { return QueueNative(env, info, 4); }
static napi_value DiscoveryRequest(napi_env env, napi_callback_info info) { return QueueNative(env, info, 6); }
static napi_value OAuthRequest(napi_env env, napi_callback_info info) { return QueueNative(env, info, 7); }

static napi_value ValidateEmailAddress(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_valuetype type;
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 1 ||
        napi_typeof(env, argv[0], &type) != napi_ok || type != napi_string) {
        napi_throw_type_error(env, nullptr, "Expected an email address string");
        return nullptr;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, argv[0], nullptr, 0, &length) != napi_ok) return nullptr;
    std::vector<char> buffer(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, argv[0], buffer.data(), buffer.size(), &copied) != napi_ok) return nullptr;
    // A C string cannot represent embedded NUL; don't silently validate a prefix.
    const bool valid = std::string(buffer.data()).size() == copied &&
        thunderbird_email_address_validate(buffer.data()) == 1;
    napi_value result;
    napi_get_boolean(env, valid, &result);
    return result;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"validateEmailAddress", nullptr, ValidateEmailAddress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mimeRequest", nullptr, MimeRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"jmapAccountRequest", nullptr, JmapAccountRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"smtpAccountRequest", nullptr, SmtpAccountRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"imapAccountRequest", nullptr, ImapAccountRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"discoveryRequest", nullptr, DiscoveryRequest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"oauthRequest", nullptr, OAuthRequest, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

static napi_module module = {1, 0, nullptr, Init, "thunderbird", nullptr, {0}};
extern "C" __attribute__((constructor)) void RegisterThunderbirdModule() {
    napi_module_register(&module);
}
