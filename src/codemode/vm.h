#ifndef FOO_CODEMODE_VM_H
#define FOO_CODEMODE_VM_H

#include <stddef.h>

typedef struct {
    const char *ptr;
    size_t len;
} foo_vm_bytes;

typedef struct {
    void *userdata;
    int (*interrupt)(void *userdata);
    int (*invoke)(void *userdata, foo_vm_bytes name, foo_vm_bytes args_json,
                  foo_vm_bytes *result_json);
    int (*text)(void *userdata, foo_vm_bytes text);
    size_t memory_bytes;
    size_t stack_bytes;
    size_t max_jobs;
} foo_vm_options;

enum {
    FOO_VM_OK = 0,
    FOO_VM_JS_ERROR,
    FOO_VM_INTERRUPTED,
    FOO_VM_JOB_LIMIT,
    FOO_VM_UNRESOLVED,
    FOO_VM_HOST_ERROR,
    FOO_VM_RESOURCE_ERROR,
};

/*
 * Callbacks run on the calling thread. Nonzero stops the invocation.
 * Callback inputs are borrowed for the duration of the call. An invoke result
 * must remain valid until the next invoke callback or foo_vm_run returns.
 * catalog_json is an array of {name, description, schema_json} records
 * with unique names. If error_capacity is positive, error points to a
 * buffer for a NUL-terminated UTF-8 diagnostic.
 */
int foo_vm_run(const foo_vm_options *options, foo_vm_bytes source,
               foo_vm_bytes catalog_json, char *error, size_t error_capacity);

#endif
