//! Value-owned work and a reserved, coalescing slot for the current listing.
const std = @import("std");
const Files = @import("file_operations");
const browser = @import("state.zig");
pub const Kind = enum { scan, trash_list, stat, open, mutate, restore, delete_trash, empty_trash };
pub const Job = struct {
    request: Files.Request,
    kind: Kind,
    note: []const u8 = "",
    listing_generation: u64 = 0,
    paste_revision: ?u64 = null,
    pub fn isListing(self: Job) bool {
        return self.kind == .scan or self.kind == .trash_list;
    }
    pub fn matchesListing(self: Job, state: *const browser.State, generation: u64) bool {
        if (self.listing_generation != generation) return false;
        return switch (self.request) {
            .scan => |scan| state.mode == .browse and std.mem.eql(u8, scan.path.slice(), state.path.slice()) and scan.sort == state.sort and scan.show_hidden == state.show_hidden and scan.descending == state.descending,
            .list_trash => state.mode == .trash,
            else => false,
        };
    }
};
pub const Pending = struct { id: u64, job: Job };
pub const Queue = struct {
    pub const capacity = 16;
    operations: std.ArrayList(Job) = .empty,
    listing: ?Job = null,
    pub fn deinit(self: *Queue, gpa: std.mem.Allocator) void {
        self.operations.deinit(gpa);
    }
    pub fn enqueue(self: *Queue, gpa: std.mem.Allocator, job: Job) !void {
        if (job.isListing()) {
            self.listing = job;
            return;
        }
        if (self.operations.items.len == capacity) return error.Full;
        try self.operations.append(gpa, job);
    }
    pub fn peek(self: *const Queue) ?Job {
        if (self.operations.items.len != 0) return self.operations.items[0];
        return self.listing;
    }
    /// Pop only after acceptance or a terminal submission failure. Busy preserves work.
    pub fn pop(self: *Queue) void {
        if (self.operations.items.len != 0) {
            _ = self.operations.orderedRemove(0);
        } else self.listing = null;
    }
};
