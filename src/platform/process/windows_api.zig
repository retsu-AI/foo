const std = @import("std");
const windows = std.os.windows;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;

pub const StartupInfo = extern struct {
    startup: windows.STARTUPINFOW,
    attributes: *AttributeList,
};

pub const AttributeList = opaque {};

pub const Attribute = enum(usize) {
    handle_list = 0x00020002,
    job_list = 0x0002000d,
};

pub const JobInfoClass = enum(c_int) {
    basic_accounting = 1,
    extended_limit = 9,
};

pub const kill_on_job_close = 0x00002000;

pub const JobLimits = extern struct {
    basic: extern struct {
        per_process_user_time: i64,
        per_job_user_time: i64,
        flags: DWORD,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: DWORD,
        affinity: usize,
        priority_class: DWORD,
        scheduling_class: DWORD,
    },
    io_counters: [6]u64,
    process_memory_limit: usize,
    job_memory_limit: usize,
    peak_process_memory_used: usize,
    peak_job_memory_used: usize,
};

pub const JobAccounting = extern struct {
    total_user_time: i64,
    total_kernel_time: i64,
    this_period_user_time: i64,
    this_period_kernel_time: i64,
    total_page_fault_count: DWORD,
    total_processes: DWORD,
    active_processes: DWORD,
    total_terminated_processes: DWORD,
};

pub const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    position: extern union {
        offset: [2]DWORD,
        pointer: ?*anyopaque,
    } = .{ .offset = .{ 0, 0 } },
    event: HANDLE,
};

pub const WaitResult = enum(DWORD) {
    signalled = 0,
    timeout = 258,
    _,
};

pub const infinite = std.math.maxInt(DWORD);

pub extern "kernel32" fn InitializeProcThreadAttributeList(?*AttributeList, DWORD, DWORD, *usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn UpdateProcThreadAttribute(*AttributeList, DWORD, Attribute, *const anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteProcThreadAttributeList(*AttributeList) callconv(.winapi) void;

pub extern "kernel32" fn CreateJobObjectW(?*windows.SECURITY_ATTRIBUTES, ?windows.LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetInformationJobObject(HANDLE, JobInfoClass, *const anyopaque, DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryInformationJobObject(HANDLE, JobInfoClass, *anyopaque, DWORD, ?*DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(HANDLE, DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetExitCodeProcess(HANDLE, *DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateEventW(?*windows.SECURITY_ATTRIBUTES, BOOL, BOOL, ?windows.LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ReadFile(HANDLE, [*]u8, DWORD, ?*DWORD, *Overlapped) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(HANDLE, [*]const u8, DWORD, ?*DWORD, *Overlapped) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(HANDLE, *Overlapped) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(HANDLE, *Overlapped, *DWORD, BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(.winapi) WaitResult;
pub extern "kernel32" fn Sleep(DWORD) callconv(.winapi) void;
pub extern "kernel32" fn GetFullPathNameW(windows.LPCWSTR, DWORD, ?[*]u16, ?*?[*]u16) callconv(.winapi) DWORD;
