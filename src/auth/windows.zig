const std = @import("std");
const win = std.os.windows;

const Sid = opaque {};
const Acl = extern struct {
    revision: u8,
    padding: u8,
    size: u16,
    ace_count: u16,
    reserved: u16,
};
const Descriptor = extern struct {
    revision: u8,
    padding: u8,
    control: u16,
    owner: ?*Sid,
    group: ?*Sid,
    sacl: ?*Acl,
    dacl: ?*Acl,
};
const AccessAce = extern struct {
    type: u8,
    flags: u8,
    size: u16,
    mask: u32,
    sid_start: u32,
};
const TokenUser = extern struct {
    sid: *Sid,
    attributes: u32,
};
const UserBuffer = [@sizeOf(TokenUser) + 68]u8;
const acl_revision = 2;
const protected_dacl = 0x1000;
const file_all_access = 0x001f01ff;
const Error = error{ IoFailure, InsecurePermissions };

extern "advapi32" fn OpenProcessToken(win.HANDLE, u32, *win.HANDLE) callconv(.winapi) win.BOOL;
extern "advapi32" fn GetTokenInformation(win.HANDLE, u32, *anyopaque, u32, *u32) callconv(.winapi) win.BOOL;
extern "advapi32" fn InitializeSecurityDescriptor(*Descriptor, u32) callconv(.winapi) win.BOOL;
extern "advapi32" fn InitializeAcl(*Acl, u32, u32) callconv(.winapi) win.BOOL;
extern "advapi32" fn AddAccessAllowedAce(*Acl, u32, u32, *Sid) callconv(.winapi) win.BOOL;
extern "advapi32" fn SetSecurityDescriptorOwner(*Descriptor, *Sid, win.BOOL) callconv(.winapi) win.BOOL;
extern "advapi32" fn SetSecurityDescriptorDacl(*Descriptor, win.BOOL, *Acl, win.BOOL) callconv(.winapi) win.BOOL;
extern "advapi32" fn SetSecurityDescriptorControl(*Descriptor, u16, u16) callconv(.winapi) win.BOOL;
extern "advapi32" fn GetSecurityInfo(win.HANDLE, u32, u32, *?*Sid, ?*anyopaque, *?*Acl, ?*anyopaque, *?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn GetSecurityDescriptorControl(*anyopaque, *u16, *u32) callconv(.winapi) win.BOOL;
extern "advapi32" fn GetAce(*Acl, u32, *?*AccessAce) callconv(.winapi) win.BOOL;
extern "advapi32" fn EqualSid(*Sid, *Sid) callconv(.winapi) win.BOOL;
extern "kernel32" fn LocalFree(*anyopaque) callconv(.winapi) ?*anyopaque;

fn currentUser(buffer: *align(@alignOf(TokenUser)) UserBuffer) Error!*Sid {
    const token_query = 0x0008;
    const token_user = 1;
    var token: win.HANDLE = undefined;
    if (OpenProcessToken(win.GetCurrentProcess(), token_query, &token) == .FALSE) return error.IoFailure;
    defer win.CloseHandle(token);
    var needed: u32 = undefined;
    if (GetTokenInformation(token, token_user, buffer, buffer.len, &needed) == .FALSE) return error.IoFailure;
    const user: *const TokenUser = @ptrCast(buffer);
    return user.sid;
}

pub fn create(dir: std.Io.Dir, name: []const u8) (Error || error{PathAlreadyExists})!std.Io.File {
    var user: UserBuffer align(@alignOf(TokenUser)) = undefined;
    const sid = try currentUser(&user);
    var acl_bytes: [@sizeOf(Acl) + @sizeOf(AccessAce) - @sizeOf(u32) + 68]u8 align(4) = undefined;
    const acl: *Acl = @ptrCast(&acl_bytes);
    var sd: Descriptor = undefined;
    if (InitializeAcl(acl, acl_bytes.len, acl_revision) == .FALSE or
        AddAccessAllowedAce(acl, acl_revision, file_all_access, sid) == .FALSE or
        InitializeSecurityDescriptor(&sd, 1) == .FALSE or
        SetSecurityDescriptorOwner(&sd, sid, .FALSE) == .FALSE or
        SetSecurityDescriptorDacl(&sd, .TRUE, acl, .FALSE) == .FALSE or
        SetSecurityDescriptorControl(&sd, protected_dacl, protected_dacl) == .FALSE) return error.IoFailure;

    var filename: [48]u16 = undefined;
    for (name, filename[0..name.len]) |byte, *wide| wide.* = byte;
    var filename_w = win.UNICODE_STRING.init(filename[0..name.len]);
    var handle: win.HANDLE = undefined;
    var status: win.IO_STATUS_BLOCK = undefined;
    switch (win.ntdll.NtCreateFile(
        &handle,
        @bitCast(@as(u32, file_all_access)),
        &.{ .RootDirectory = dir.handle, .ObjectName = &filename_w, .SecurityDescriptor = &sd, .Attributes = .{ .DONT_REPARSE = true } },
        &status,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .CREATE,
        .{ .NON_DIRECTORY_FILE = true, .IO = .SYNCHRONOUS_NONALERT },
        null,
        0,
    )) {
        .SUCCESS => return .{ .handle = handle, .flags = .{ .nonblocking = false } },
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        else => return error.IoFailure,
    }
}

pub fn check(file: std.Io.File) Error!void {
    const se_file_object = 1;
    const owner_security_information = 1;
    const dacl_security_information = 4;
    var owner: ?*Sid = null;
    var acl: ?*Acl = null;
    var descriptor: ?*anyopaque = null;
    if (GetSecurityInfo(file.handle, se_file_object, owner_security_information | dacl_security_information, &owner, null, &acl, null, &descriptor) != 0)
        return error.IoFailure;
    const sd = descriptor orelse return error.InsecurePermissions;
    defer _ = LocalFree(sd);
    var user: UserBuffer align(@alignOf(TokenUser)) = undefined;
    const sid = try currentUser(&user);
    if (EqualSid(sid, owner orelse return error.InsecurePermissions) == .FALSE) return error.InsecurePermissions;
    const dacl = acl orelse return error.InsecurePermissions;
    var flags: u16 = undefined;
    var revision: u32 = undefined;
    if (GetSecurityDescriptorControl(sd, &flags, &revision) == .FALSE) return error.IoFailure;
    if (flags & protected_dacl == 0 or dacl.ace_count != 1) return error.InsecurePermissions;

    var raw: ?*AccessAce = null;
    if (GetAce(dacl, 0, &raw) == .FALSE) return error.IoFailure;
    const ace = raw orelse return error.InsecurePermissions;
    const access_allowed_ace = 0;
    if (ace.type != access_allowed_ace or EqualSid(sid, @ptrCast(&ace.sid_start)) == .FALSE) return error.InsecurePermissions;
}
