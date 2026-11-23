#include "vm.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "quickjs.h"

typedef struct {
    const foo_vm_options *host;
    JSValue to_well_formed;
    bool capabilities_enabled;
    int status;
    const char *failure;
} vm_run;

static void fail(vm_run *run, int status, const char *message)
{
    if (run->status == FOO_VM_OK) {
        run->status = status;
        run->failure = message;
    }
}

static int check_interrupt(JSContext *ctx, void *opaque)
{
    (void)ctx;
    vm_run *run = opaque;
    if (run->status == FOO_VM_OK && run->host->interrupt(run->host->userdata))
        fail(run, FOO_VM_INTERRUPTED, "JavaScript execution interrupted");
    return run->status != FOO_VM_OK;
}

static JSValue parse_json(JSContext *ctx, foo_vm_bytes bytes)
{
    if (bytes.ptr == NULL || bytes.len == SIZE_MAX ||
        memchr(bytes.ptr, '\0', bytes.len) != NULL)
        return JS_ThrowSyntaxError(ctx, "invalid JSON bytes");

    // JS_ParseJSON requires a NUL beyond the input slice.
    char *terminated = js_malloc(ctx, bytes.len + 1);
    if (terminated == NULL)
        return JS_EXCEPTION;
    memcpy(terminated, bytes.ptr, bytes.len);
    terminated[bytes.len] = '\0';
    JSValue result = JS_ParseJSON(ctx, terminated, bytes.len, "code-mode.json");
    js_free(ctx, terminated);
    return result;
}

static JSValue call_tool(JSContext *ctx, JSValueConst this_value, int argc,
                         JSValueConst *argv, int magic, JSValueConst *data)
{
    (void)this_value;
    (void)magic;
    vm_run *run = JS_GetContextOpaque(ctx);
    if (!run->capabilities_enabled)
        return JS_ThrowTypeError(ctx, "tools are unavailable during value conversion");
    if (check_interrupt(ctx, run))
        return JS_ThrowInternalError(ctx, "%s", run->failure);
    if (argc > 1)
        return JS_ThrowTypeError(ctx, "a tool accepts at most one argument");

    // JSON.stringify may execute getters or toJSON.
    run->capabilities_enabled = false;
    JSValue json = argc == 0 || JS_IsUndefined(argv[0])
        ? JS_NewString(ctx, "{}")
        : JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    run->capabilities_enabled = true;
    if (JS_IsException(json))
        return JS_EXCEPTION;
    if (JS_IsUndefined(json))
        return JS_ThrowTypeError(ctx, "tool argument must serialize to JSON");

    foo_vm_bytes args;
    args.ptr = JS_ToCStringLen(ctx, &args.len, json);
    JS_FreeValue(ctx, json);
    if (args.ptr == NULL)
        return JS_EXCEPTION;

    foo_vm_bytes name;
    name.ptr = JS_ToCStringLen(ctx, &name.len, data[0]);
    if (name.ptr == NULL) {
        JS_FreeCString(ctx, args.ptr);
        return JS_EXCEPTION;
    }
    foo_vm_bytes response = {0};
    if (!check_interrupt(ctx, run)) {
        int code = run->host->invoke(run->host->userdata, name, args, &response);
        if (!check_interrupt(ctx, run) && code != 0)
            fail(run, FOO_VM_HOST_ERROR, "tool dispatch failed");
    }
    JS_FreeCString(ctx, name.ptr);
    JS_FreeCString(ctx, args.ptr);

    if (run->status != FOO_VM_OK)
        return JS_ThrowInternalError(ctx, "%s", run->failure);

    JSValue result = parse_json(ctx, response);
    if (JS_IsException(result)) {
        JSValue reason = JS_GetException(ctx);
        if (JS_IsUncatchableError(reason))
            fail(run, FOO_VM_RESOURCE_ERROR, "JavaScript resource limit exceeded");
        else
            fail(run, FOO_VM_HOST_ERROR, "tool returned invalid JSON");
        JS_FreeValue(ctx, reason);
        return JS_ThrowInternalError(ctx, "%s", run->failure);
    }
    return result;
}

static JSValue emit_text(JSContext *ctx, vm_run *run, JSValueConst value)
{
    if (check_interrupt(ctx, run))
        return JS_ThrowInternalError(ctx, "%s", run->failure);

    bool previous = run->capabilities_enabled;
    run->capabilities_enabled = false;
    JSValue string = JS_IsObject(value)
        ? JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED)
        : JS_ToString(ctx, value);
    run->capabilities_enabled = previous;
    if (JS_IsException(string))
        return JS_EXCEPTION;
    if (JS_IsUndefined(string))
        return JS_ThrowTypeError(ctx, "text value must serialize to JSON");

    // The QuickJS UTF-8 accessor preserves lone UTF-16 surrogates.
    JSValue well_formed = JS_Call(ctx, run->to_well_formed, string, 0, NULL);
    JS_FreeValue(ctx, string);
    if (JS_IsException(well_formed))
        return JS_EXCEPTION;

    foo_vm_bytes bytes;
    bytes.ptr = JS_ToCStringLen(ctx, &bytes.len, well_formed);
    JS_FreeValue(ctx, well_formed);
    if (bytes.ptr == NULL)
        return JS_EXCEPTION;

    if (!check_interrupt(ctx, run)) {
        int code = run->host->text(run->host->userdata, bytes);
        if (!check_interrupt(ctx, run) && code != 0)
            fail(run, FOO_VM_HOST_ERROR, "text output failed");
    }
    JS_FreeCString(ctx, bytes.ptr);
    if (run->status != FOO_VM_OK)
        return JS_ThrowInternalError(ctx, "%s", run->failure);
    return JS_UNDEFINED;
}

static JSValue text_callback(JSContext *ctx, JSValueConst this_value, int argc,
                             JSValueConst *argv)
{
    (void)this_value;
    vm_run *run = JS_GetContextOpaque(ctx);
    if (!run->capabilities_enabled)
        return JS_ThrowTypeError(ctx, "text is unavailable during value conversion");
    return emit_text(ctx, run, argc == 0 ? JS_UNDEFINED : argv[0]);
}

static JSValue make_tools(JSContext *ctx, JSValueConst catalog)
{
    int64_t count;
    if (!JS_IsArray(catalog))
        return JS_ThrowTypeError(ctx, "expected an array of tool declarations");
    if (JS_GetLength(ctx, catalog, &count) < 0)
        return JS_EXCEPTION;

    JSValue tools = JS_NewObjectProto(ctx, JS_NULL);
    if (JS_IsException(tools))
        return JS_EXCEPTION;
    for (int64_t index = 0; index < count; ++index) {
        JSValue declaration = JS_GetPropertyUint32(ctx, catalog, (uint32_t)index);
        if (JS_IsException(declaration))
            goto failed;
        if (!JS_IsObject(declaration)) {
            JS_FreeValue(ctx, declaration);
            JS_ThrowTypeError(ctx, "expected a tool declaration");
            goto failed;
        }
        JSValue name = JS_GetPropertyStr(ctx, declaration, "name");
        JSValue description = JS_GetPropertyStr(ctx, declaration, "description");
        JSValue schema = JS_GetPropertyStr(ctx, declaration, "schema_json");
        bool valid = JS_IsString(name) && JS_IsString(description) && JS_IsString(schema);
        if (!valid && !JS_HasException(ctx))
            JS_ThrowTypeError(ctx, "expected string fields in tool declaration");
        int frozen = valid ? JS_FreezeObject(ctx, declaration) : -1;
        JS_FreeValues(ctx, declaration, description, schema);
        if (frozen < 0) {
            JS_FreeValue(ctx, name);
            goto failed;
        }

        JSAtom key = JS_ValueToAtom(ctx, name);
        JSValue tool = key == JS_ATOM_NULL
            ? JS_EXCEPTION
            : JS_NewCFunctionData(ctx, call_tool, 1, 0, 1, &name);
        JS_FreeValue(ctx, name);
        int defined = JS_IsException(tool)
            ? -1
            : JS_DefinePropertyValue(ctx, tools, key, tool,
                                     JS_PROP_ENUMERABLE | JS_PROP_THROW);
        JS_FreeAtom(ctx, key);
        if (defined < 0)
            goto failed;
    }

    if (JS_FreezeObject(ctx, catalog) < 0 || JS_PreventExtensions(ctx, tools) < 0)
        goto failed;
    return tools;

failed:
    JS_FreeValue(ctx, tools);
    return JS_EXCEPTION;
}

static JSValue compile_body(JSContext *ctx, foo_vm_bytes source)
{
    static const char prefix[] = "(async function(tools, text, ALL_TOOLS) {\n";
    static const char suffix[] = "\n})";
    const size_t wrapper_len = sizeof(prefix) - 1 + sizeof(suffix) - 1;
    if (source.len > SIZE_MAX - wrapper_len - 1)
        return JS_ThrowOutOfMemory(ctx);
    if (source.len != 0 && memchr(source.ptr, '\0', source.len) != NULL)
        return JS_ThrowSyntaxError(ctx, "source contains a NUL byte");

    size_t length = source.len + wrapper_len;
    char *wrapped = js_malloc(ctx, length + 1);
    if (wrapped == NULL)
        return JS_EXCEPTION;
    memcpy(wrapped, prefix, sizeof(prefix) - 1);
    if (source.len != 0)
        memcpy(wrapped + sizeof(prefix) - 1, source.ptr, source.len);
    memcpy(wrapped + sizeof(prefix) - 1 + source.len, suffix, sizeof(suffix));

    JSValue function_proto = JS_GetFunctionProto(ctx);
    JSValue to_string = JS_GetPropertyStr(ctx, function_proto, "toString");
    JSValue body = JS_EXCEPTION;
    JS_FreeValue(ctx, function_proto);
    if (!JS_IsException(to_string)) {
        body = JS_Eval(ctx, wrapped, length, "code-mode.js",
                       JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT);
    }

    if (JS_IsAsyncFunction(body)) {
        JSValue actual = JS_Call(ctx, to_string, body, 0, NULL);
        size_t actual_len;
        const char *actual_bytes = JS_IsException(actual)
            ? NULL
            : JS_ToCStringLen(ctx, &actual_len, actual);
        bool is_complete_body = actual_bytes != NULL && actual_len == length - 2 &&
            memcmp(actual_bytes, wrapped + 1, actual_len) == 0;
        JS_FreeCString(ctx, actual_bytes);
        JS_FreeValue(ctx, actual);
        if (!is_complete_body) {
            JS_FreeValue(ctx, body);
            body = JS_HasException(ctx)
                ? JS_EXCEPTION
                : JS_ThrowSyntaxError(ctx, "expected a single async function body");
        }
    } else if (!JS_IsException(body)) {
        JS_FreeValue(ctx, body);
        body = JS_ThrowSyntaxError(ctx, "expected a single async function body");
    }
    JS_FreeValue(ctx, to_string);
    js_free(ctx, wrapped);
    return body;
}

static void write_diagnostic(char *output, size_t capacity, const char *message, size_t length)
{
    if (capacity == 0)
        return;
    size_t copy = length < capacity ? length : capacity - 1;
    while (copy != length && copy > 0 && ((unsigned char)message[copy] & 0xc0) == 0x80)
        --copy;
    memcpy(output, message, copy);
    output[copy] = '\0';
}

static void report_exception(JSContext *ctx, vm_run *run, JSValueConst reason,
                             char *error, size_t capacity)
{
    if (JS_IsUncatchableError(reason)) {
        fail(run, FOO_VM_RESOURCE_ERROR, "JavaScript resource limit exceeded");
        return;
    }

    const char *fallback = "JavaScript threw a value";
    write_diagnostic(error, capacity, fallback, strlen(fallback));

    JSValue message = JS_UNDEFINED;
    if (JS_IsString(reason)) {
        message = JS_DupValue(ctx, reason);
    } else if (JS_IsError(reason)) {
        JSAtom key = JS_NewAtom(ctx, "message");
        JSPropertyDescriptor desc;
        if (key != JS_ATOM_NULL && JS_GetOwnProperty(ctx, &desc, reason, key) > 0) {
            message = desc.value;
            JS_FreeValues(ctx, desc.getter, desc.setter);
        }
        JS_FreeAtom(ctx, key);
    }
    if (JS_IsString(message) && !JS_IsException(run->to_well_formed)) {
        JSValue normalized = JS_Call(ctx, run->to_well_formed, message, 0, NULL);
        size_t length;
        const char *bytes = JS_IsException(normalized)
            ? NULL
            : JS_ToCStringLen(ctx, &length, normalized);
        if (bytes != NULL && length != 0)
            write_diagnostic(error, capacity, bytes, length);
        JS_FreeCString(ctx, bytes);
        JS_FreeValue(ctx, normalized);
    }
    JS_FreeValue(ctx, message);
    fail(run, FOO_VM_JS_ERROR, NULL);
}

static void settle(JSContext *ctx, vm_run *run, JSValueConst promise,
                   char *error, size_t capacity)
{
    JSRuntime *runtime = JS_GetRuntime(ctx);
    size_t jobs = 0;
    JSPromiseStateEnum state = JS_PromiseState(ctx, promise);
    while (state == JS_PROMISE_PENDING) {
        if (check_interrupt(ctx, run))
            return;
        if (!JS_IsJobPending(runtime)) {
            fail(run, FOO_VM_UNRESOLVED, "JavaScript returned a pending promise with no runnable jobs");
            return;
        }
        if (jobs == run->host->max_jobs) {
            fail(run, FOO_VM_JOB_LIMIT, "JavaScript job limit exceeded");
            return;
        }

        JSContext *job_ctx;
        ++jobs;
        if (JS_ExecutePendingJob(runtime, &job_ctx) < 0) {
            if (run->status == FOO_VM_OK) {
                JSValue reason = JS_GetException(job_ctx);
                report_exception(job_ctx, run, reason, error, capacity);
                JS_FreeValue(job_ctx, reason);
            }
            return;
        }
        state = JS_PromiseState(ctx, promise);
    }

    run->capabilities_enabled = false;
    if (check_interrupt(ctx, run))
        return;
    if (state == JS_PROMISE_NOT_A_PROMISE) {
        fail(run, FOO_VM_RESOURCE_ERROR, "JavaScript body did not produce a promise");
        return;
    }

    JSValue result = JS_PromiseResult(ctx, promise);
    if (state == JS_PROMISE_REJECTED) {
        report_exception(ctx, run, result, error, capacity);
    } else if (!JS_IsUndefined(result)) {
        JSValue emitted = emit_text(ctx, run, result);
        if (JS_IsException(emitted) && run->status == FOO_VM_OK) {
            JSValue reason = JS_GetException(ctx);
            report_exception(ctx, run, reason, error, capacity);
            JS_FreeValue(ctx, reason);
        }
        JS_FreeValue(ctx, emitted);
    }
    JS_FreeValue(ctx, result);
}

int foo_vm_run(const foo_vm_options *options, foo_vm_bytes source,
               foo_vm_bytes catalog_json, char *error, size_t error_capacity)
{
    if (error_capacity != 0)
        error[0] = '\0';
    vm_run run = {.host = options};
    if (options == NULL || options->interrupt == NULL || options->invoke == NULL ||
        options->text == NULL || options->memory_bytes == 0 || options->stack_bytes == 0 ||
        (source.ptr == NULL && source.len != 0)) {
        fail(&run, FOO_VM_HOST_ERROR, "invalid JavaScript execution options");
        goto finished;
    }
    if (check_interrupt(NULL, &run))
        goto finished;

    JSRuntime *runtime = JS_NewRuntime();
    if (runtime == NULL) {
        fail(&run, FOO_VM_RESOURCE_ERROR, "unable to allocate a JavaScript runtime");
        goto finished;
    }
    JS_SetMemoryLimit(runtime, options->memory_bytes);
    JS_SetMaxStackSize(runtime, options->stack_bytes);
    JS_SetCanBlock(runtime, false);
    JS_SetInterruptHandler(runtime, check_interrupt, &run);

    JSContext *ctx = JS_NewContext(runtime);
    if (ctx == NULL) {
        fail(&run, FOO_VM_RESOURCE_ERROR, "unable to allocate a JavaScript context");
        JS_FreeRuntime(runtime);
        goto finished;
    }
    JS_SetContextOpaque(ctx, &run);

    JSValue empty = JS_NewString(ctx, "");
    run.to_well_formed = JS_IsException(empty)
        ? JS_EXCEPTION
        : JS_GetPropertyStr(ctx, empty, "toWellFormed");
    JS_FreeValue(ctx, empty);
    JSValue catalog = JS_UNDEFINED;
    JSValue tools = JS_UNDEFINED;
    JSValue text = JS_UNDEFINED;
    JSValue body = JS_UNDEFINED;
    JSValue promise = JS_UNDEFINED;
    if (JS_IsException(run.to_well_formed))
        goto exception;

    catalog = parse_json(ctx, catalog_json);
    if (!JS_IsException(catalog))
        tools = make_tools(ctx, catalog);
    if (JS_IsException(catalog) || JS_IsException(tools)) {
        JSValue reason = JS_GetException(ctx);
        if (JS_IsUncatchableError(reason))
            fail(&run, FOO_VM_RESOURCE_ERROR, "JavaScript resource limit exceeded");
        else
            fail(&run, FOO_VM_HOST_ERROR, "invalid JavaScript tool catalog");
        JS_FreeValue(ctx, reason);
        goto clean_up;
    }
    text = JS_NewCFunction(ctx, text_callback, "text", 1);
    if (JS_IsException(text))
        goto exception;
    body = compile_body(ctx, source);
    if (JS_IsException(body))
        goto exception;
    if (check_interrupt(ctx, &run))
        goto clean_up;

    JSValueConst args[] = {tools, text, catalog};
    run.capabilities_enabled = true;
    promise = JS_Call(ctx, body, JS_UNDEFINED, 3, args);
    if (JS_IsException(promise))
        goto exception;
    settle(ctx, &run, promise, error, error_capacity);
    goto clean_up;

exception:
    run.capabilities_enabled = false;
    if (run.status == FOO_VM_OK) {
        JSValue reason = JS_GetException(ctx);
        report_exception(ctx, &run, reason, error, error_capacity);
        JS_FreeValue(ctx, reason);
    }

clean_up:
    JS_FreeValues(ctx, promise, body, text, tools, catalog, run.to_well_formed);
    JS_FreeContext(ctx);
    JS_FreeRuntime(runtime);

finished:
    if (run.failure != NULL)
        write_diagnostic(error, error_capacity, run.failure, strlen(run.failure));
    return run.status;
}
