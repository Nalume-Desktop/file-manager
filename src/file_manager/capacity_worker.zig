//! Single-slot capacity query worker. Owner requests and polls never wait.
//! The path is copied before spawning; only destroy joins storage work.
const std = @import("std");
const Text = @import("state.zig").Text;

pub const Usage = struct { total: u64, free: u64 };
pub const Completion = struct { usage: ?Usage };

const libc = struct {
    const Statvfs = extern struct {
        f_bsize: usize,
        f_frsize: usize,
        f_blocks: usize,
        f_bfree: usize,
        f_bavail: usize,
        f_files: usize,
        f_ffree: usize,
        f_favail: usize,
        f_fsid: usize,
        f_flag: usize,
        f_namemax: usize,
        spare: [6]c_int,
    };
    extern "c" fn statvfs(path: [*:0]const u8, buffer: *Statvfs) c_int;
};

/// Called on the worker without its mutex held. Context must outlive destroy.
pub const Query = struct {
    context: ?*anyopaque = null,
    queryFn: *const fn (?*anyopaque, []const u8) ?Usage = query,

    fn query(_: ?*anyopaque, path: []const u8) ?Usage {
        var buffer: [4096]u8 = undefined;
        if (path.len == 0 or path.len >= buffer.len) return null;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        var info: libc.Statvfs = undefined;
        if (libc.statvfs(@ptrCast(&buffer), &info) != 0) return null;
        const block: u64 = @intCast(info.f_frsize);
        const total = std.math.mul(u64, @intCast(info.f_blocks), block) catch return null;
        const free = std.math.mul(u64, @intCast(info.f_bavail), block) catch return null;
        return .{ .total = total, .free = free };
    }
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: Text,
    query: Query,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    stopping: bool = false,
    outstanding: bool = false,
    pending: bool = false,
    completion: ?Completion = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !*Worker {
        return createWithQuery(gpa, io, path, .{});
    }

    pub fn createWithQuery(gpa: std.mem.Allocator, io: std.Io, path: []const u8, query: Query) !*Worker {
        const self = try gpa.create(Worker);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .path = try Text.init(path), .query = query };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
        return self;
    }

    /// At most one accepted request, including an unread completion.
    pub fn request(self: *Worker) error{ Busy, Stopped }!void {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Stopped;
        if (self.outstanding) return error.Busy;
        self.outstanding = true;
        self.pending = true;
        self.wake.signal(self.io);
    }

    pub fn takeCompletion(self: *Worker) ?Completion {
        if (!self.mutex.tryLock()) return null;
        defer self.mutex.unlock(self.io);
        const result = self.completion orelse return null;
        self.completion = null;
        self.outstanding = false;
        return result;
    }

    /// Sole blocking owner operation. Finishes accepted work before freeing path.
    pub fn destroy(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.wake.signal(self.io);
        self.mutex.unlock(self.io);
        self.thread.?.join();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn workerMain(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            while (!self.pending and !self.stopping)
                self.wake.waitUncancelable(self.io, &self.mutex);
            if (!self.pending) return;
            self.pending = false;
            self.mutex.unlock(self.io);
            const usage = self.query.queryFn(self.query.context, self.path.slice());
            self.mutex.lockUncancelable(self.io);
            std.debug.assert(self.completion == null);
            self.completion = .{ .usage = usage };
        }
    }
};

/// Owner-side cache shared by the frame loop and render. Refreshing is optional;
/// rendering reads usage even while a query is slow or fails.
pub const Cache = struct {
    usage: ?Usage = null,
    requested_at: ?u64 = null,

    pub fn refresh(self: *Cache, worker: *Worker, now_ms: u64) bool {
        var changed = false;
        if (worker.takeCompletion()) |completion| {
            if (completion.usage) |usage| {
                self.usage = usage;
                changed = true;
            }
        }
        if (self.requested_at) |at| if (now_ms -| at < 5_000) return changed;
        worker.request() catch return changed;
        self.requested_at = now_ms;
        return changed;
    }
};
