const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Capture = @import("router/routing_trie.zig").Capture;
const TypedStorage = @import("../core/typed_storage.zig").TypedStorage;
const AnyCaseStringMap = @import("../core/any_case_string_map.zig").AnyCaseStringMap;

/// HTTP Context. Contains all of the various information
/// that will persist throughout the lifetime of this Request/Response.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// The Request that triggered this handler.
    request: *const Request,
    response: *Response,
    /// Storage
    storage: *TypedStorage,
    /// Socket for this Connection.
    stream: std.Io.net.Stream,
    /// Slice of the URL Slug Captures
    captures: []const Capture,
    /// Map of the KV Query pairs in the URL
    queries: *const AnyCaseStringMap,
};
