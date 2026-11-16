const std = @import("std");

/// IDs retain their type. A notification has no ID, represented outside this type.
pub const Id = union(enum) {
    number: i64,
    string: []const u8,

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .number => |v| switch (b) {
                .number => |w| v == w,
                .string => false,
            },
            .string => |v| switch (b) {
                .string => |w| std.mem.eql(u8, v, w),
                .number => false,
            },
        };
    }
};
pub const Direction = enum { inbound, outbound };
pub const Request = struct { id: ?Id, method: []const u8, params_json: ?[]const u8 = null };
pub const RpcError = struct { code: i32, message: []const u8, data_json: ?[]const u8 = null };
pub const Response = union(enum) {
    success: struct { id: Id, result_json: []const u8 },
    /// The protocol codec encodes an unknown ID as null or absent as required.
    failure: struct { id: ?Id = null, err: RpcError },
};
pub const Code = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};
