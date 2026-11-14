//! Pure-state tests for the standalone file manager.
const std = @import("std");
const browser = @import("file_manager/state.zig");
const Files = @import("file_operations");

test "history keeps a bounded, de-duplicated trail" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    var history = &state.history;
    try history.push("/a");
    try history.push("/b");
    try std.testing.expectEqualStrings("/b", history.current().?);
    try std.testing.expectEqualStrings("/a", history.back().?);
    try std.testing.expectEqualStrings("/b", history.forward().?);
    try std.testing.expect(history.forward() == null);
    try history.push("/b");
    try std.testing.expectEqual(@as(usize, 2), history.count);
    try history.push("/c");
    try std.testing.expectEqual(@as(usize, 3), history.count);
    try std.testing.expectEqual(@as(usize, 2), history.index);
}

test "listing import maps entries and preserves selection by path" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    var entries = [_]Files.Entry{
        .{ .name = try Files.Text.init("a.txt"), .path = try Files.Text.init("/tmp/a.txt"), .kind = .file, .size = 12, .modified = 5 },
        .{ .name = try Files.Text.init("dir"), .path = try Files.Text.init("/tmp/dir"), .kind = .directory, .size = 0, .modified = 0 },
    };
    var listing: Files.Listing = .{ .entries = &entries };
    state.applyListing(&listing);
    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expectEqualStrings("dir", state.items.items[1].name());
    state.select(1);
    state.applyListing(&listing);
    try std.testing.expectEqual(@as(?usize, 1), state.selected);
    state.applyTrashListing(&.{ .entries = &.{} });
    try std.testing.expectEqual(@as(usize, 0), state.items.items.len);
}

test "hidden files and query filter visible rows" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    var entries = [_]Files.Entry{
        .{ .name = try Files.Text.init(".hidden"), .path = try Files.Text.init("/tmp/.hidden"), .kind = .file, .size = 0, .modified = 0 },
        .{ .name = try Files.Text.init("Report.PDF"), .path = try Files.Text.init("/tmp/Report.PDF"), .kind = .file, .size = 0, .modified = 0 },
        .{ .name = try Files.Text.init("notes.txt"), .path = try Files.Text.init("/tmp/notes.txt"), .kind = .file, .size = 0, .modified = 0 },
    };
    var listing: Files.Listing = .{ .entries = &entries };
    state.applyListing(&listing);
    try std.testing.expectEqual(@as(usize, 2), state.visibleCount());
    state.show_hidden = true;
    try std.testing.expectEqual(@as(usize, 3), state.visibleCount());
    state.setQuery("report");
    try std.testing.expectEqual(@as(usize, 1), state.visibleCount());
    try std.testing.expectEqual(@as(?usize, 1), state.visibleAt(0));
    state.setQuery("");
    try std.testing.expectEqual(@as(usize, 3), state.visibleCount());
}

test "trash import keeps ids and original paths" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    var entries = [_]Files.TrashEntry{
        .{ .id = try Files.Text.init("abc"), .name = try Files.Text.init("old.txt"), .path = try Files.Text.init("/home/x/old.txt"), .kind = .file, .size = 3, .modified = 9, .original_path = try Files.Text.init("/home/x/old.txt"), .deleted_at = try Files.Text.init("2026-01-01T00:00:00") },
    };
    var listing: Files.TrashListing = .{ .entries = &entries };
    state.applyTrashListing(&listing);
    try std.testing.expectEqual(@as(usize, 1), state.items.items.len);
    try std.testing.expectEqualStrings("abc", state.items.items[0].trash_id.slice());
    try std.testing.expectEqualStrings("/home/x/old.txt", state.items.items[0].path.slice());
}

test "toast expires" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    state.notify(1000, "hello");
    try std.testing.expectEqualStrings("hello", state.toastText(1001));
    try std.testing.expectEqualStrings("", state.toastText(6000));
}

test "dialog text buffers round-trip" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    try state.items.append(state.allocator, .{ .label = try Files.Text.init("old"), .path = try Files.Text.init("/old") });
    state.startDialog(.rename, 0, "old");
    try std.testing.expectEqualStrings("old", state.dialog.text.items);
    state.closeDialog();
    try std.testing.expectEqual(browser.DialogKind.none, state.dialog.kind);
    try std.testing.expectEqual(@as(usize, 0), state.dialog.text.items.len);
}

const files_worker = @import("file_operations").worker;
const capacity = @import("file_manager/capacity_worker.zig");

fn submitFile(worker: *files_worker.Worker, id: u64, request: Files.Request) !void {
    for (0..100_000) |_| {
        worker.submit(id, request) catch |err| switch (err) {
            error.Busy => {
                try std.Thread.yield();
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.TestSubmitTimedOut;
}

fn takeFile(worker: *files_worker.Worker) !files_worker.Completion {
    for (0..100_000) |_| {
        if (worker.takeCompletion()) |result| return result;
        try std.Thread.yield();
    }
    return error.TestCompletionTimedOut;
}

fn testEntry(name: []const u8) !Files.Entry {
    var path: [128]u8 = undefined;
    return .{
        .name = try Files.Text.init(name),
        .path = try Files.Text.init(try std.fmt.bufPrint(&path, "/listing/{s}", .{name})),
        .kind = .file,
        .size = 0,
        .modified = 0,
    };
}

fn testTrashEntry(id: []const u8) !Files.TrashEntry {
    return .{
        .id = try Files.Text.init(id),
        .name = try Files.Text.init(id),
        .path = try Files.Text.init("/trash/files"),
        // Distinct Trash IDs may describe the same recreated original path.
        .original_path = try Files.Text.init("/listing/recreated"),
        .deleted_at = .{},
        .kind = .file,
        .size = 0,
        .modified = 0,
    };
}

/// Real async worker completions replace the listing before confirmation. No
/// filesystem mutations: the executor records the dispatched request in its
/// completion, so a retargeted operation fails without touching user data.
const ReplacementListing = struct {
    remove_a: bool,

    fn execute(context: ?*anyopaque, _: *const Files.Service, allocator: std.mem.Allocator, request: Files.Request) anyerror!Files.Result {
        const self: *ReplacementListing = @ptrCast(@alignCast(context.?));
        const count: usize = if (self.remove_a) 1 else 2;
        switch (request) {
            .scan => {
                const entries = try allocator.alloc(Files.Entry, count);
                errdefer allocator.free(entries);
                entries[0] = try testEntry("B");
                if (!self.remove_a) entries[1] = try testEntry("A");
                return .{ .listing = .{ .entries = entries } };
            },
            .list_trash => {
                const entries = try allocator.alloc(Files.TrashEntry, count);
                errdefer allocator.free(entries);
                entries[0] = try testTrashEntry("B-id");
                if (!self.remove_a) entries[1] = try testTrashEntry("A-id");
                return .{ .trash_listing = .{ .entries = entries } };
            },
            else => return .{ .done = {} },
        }
    }
};

test "async listing reorder and removal never retarget dialog A to B" {
    for ([_]browser.DialogKind{ .rename, .confirm_trash, .confirm_delete }) |kind| {
        for ([_]bool{ false, true }) |remove_a| {
            var state = browser.State.init(std.testing.allocator);
            defer state.deinit();
            try state.path.set("/listing");
            const trash = kind == .confirm_delete;
            state.mode = if (trash) .trash else .browse;
            var entries = [_]Files.Entry{ try testEntry("A"), try testEntry("B") };
            var trash_entries = [_]Files.TrashEntry{ try testTrashEntry("A-id"), try testTrashEntry("B-id") };
            if (trash) state.applyTrashListing(&.{ .entries = &trash_entries }) else state.applyListing(&.{ .entries = &entries });
            state.startDialog(kind, 0, "A");

            var replacement: ReplacementListing = .{ .remove_a = remove_a };
            const worker = try files_worker.Worker.createWithExecutor(std.testing.allocator, std.testing.io, .{}, .{ .context = &replacement, .executeFn = ReplacementListing.execute });
            defer if (worker.destroy()) |value| {
                var completion = value;
                completion.deinit();
            };
            try submitFile(worker, 1, if (trash) .{ .list_trash = {} } else .{ .scan = .{ .path = state.path } });
            var listing = try takeFile(worker);
            defer listing.deinit();
            try std.testing.expect(listing.error_code == null);
            if (trash) state.descending = true; // Preserve the forced B-before-A replacement under local sorting.
            switch (listing.result.?) {
                .listing => |value| state.applyListing(&value),
                .trash_listing => |value| state.applyTrashListing(&value),
                else => return error.UnexpectedResult,
            }
            try std.testing.expectEqualStrings(if (trash) "B-id" else "B", state.items.items[0].name());
            const request = state.confirmDialog(try Files.Text.init("renamed")) orelse return error.MissingConfirmation;
            // Prove the request survives the UI-to-worker dispatch boundary too.
            try submitFile(worker, 2, request);
            var confirmation = try takeFile(worker);
            defer confirmation.deinit();
            try std.testing.expect(confirmation.error_code == null);
            switch (kind) {
                .rename => {
                    try std.testing.expectEqualStrings("/listing/A", confirmation.request.rename.path.slice());
                    try std.testing.expectEqualStrings("renamed", confirmation.request.rename.name.slice());
                },
                .confirm_trash => try std.testing.expectEqualStrings("/listing/A", confirmation.request.trash.slice()),
                .confirm_delete => {
                    try std.testing.expectEqualStrings("A-id", confirmation.request.delete_trash.id.slice());
                    try std.testing.expect(confirmation.request.delete_trash.confirmed);
                },
                else => unreachable,
            }
            try std.testing.expectEqual(browser.DialogKind.none, state.dialog.kind);
        }
    }
}

test "Trash copy and cut cannot stash a recreated live path and browse still works" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .trash;
    var trash_entries = [_]Files.TrashEntry{try testTrashEntry("A-id")};
    state.applyTrashListing(&.{ .entries = &trash_entries });
    try std.testing.expect(!state.canStash(0));
    try std.testing.expect(!state.stash(0, false));
    try std.testing.expect(!state.stash(0, true));
    try std.testing.expect(state.clipboard == null);

    // While navigation is waiting for its listing, Trash rows still cannot be
    // treated as live objects even if the mode has already changed to browse.
    state.mode = .browse;
    try std.testing.expect(!state.stash(0, true));
    var live_entries = [_]Files.Entry{try testEntry("recreated")};
    state.applyListing(&.{ .entries = &live_entries });
    try std.testing.expect(state.clipboard == null);
    try std.testing.expect(state.stash(0, false));
    try std.testing.expect(!state.clipboard.?.cut);
    try std.testing.expectEqualStrings("/listing/recreated", state.clipboard.?.path.slice());
    try std.testing.expect(state.stash(0, true));
    try std.testing.expect(state.clipboard.?.cut);

    // A rejected Trash action must preserve a previous legitimate clipboard.
    state.mode = .trash;
    state.applyTrashListing(&.{ .entries = &trash_entries });
    try std.testing.expect(!state.stash(0, false));
    try std.testing.expect(state.clipboard.?.cut);
    try std.testing.expectEqualStrings("/listing/recreated", state.clipboard.?.path.slice());
}

const HeldCapacity = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    entered: bool = false,
    released: bool = false,
    calls: usize = 0,
    path: Files.Text = .{},
    usage: ?capacity.Usage = .{ .total = 200, .free = 80 },

    fn query(context: ?*anyopaque, path: []const u8) ?capacity.Usage {
        const self: *HeldCapacity = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.calls += 1;
        self.entered = true;
        self.wake.broadcast(self.io);
        while (!self.released) self.wake.waitUncancelable(self.io, &self.mutex);
        self.path = Files.Text.init(path) catch unreachable;
        return self.usage;
    }

    fn waitEntered(self: *HeldCapacity) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (!self.entered) self.wake.waitUncancelable(self.io, &self.mutex);
    }

    fn release(self: *HeldCapacity) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.released = true;
        self.wake.broadcast(self.io);
    }
};

fn refreshUntilIdle(cache: *capacity.Cache, worker: *capacity.Worker, now: u64) !void {
    for (0..100_000) |_| {
        _ = cache.refresh(worker, now);
        worker.mutex.lockUncancelable(worker.io);
        const outstanding = worker.outstanding;
        worker.mutex.unlock(worker.io);
        if (!outstanding) return;
        try std.Thread.yield();
    }
    return error.TestCompletionTimedOut;
}

test "slow capacity query keeps cached paint nonblocking and bounds outstanding work" {
    var path = try Files.Text.init("/owned-home");
    var gate: HeldCapacity = .{ .io = std.testing.io };
    const worker = try capacity.Worker.createWithQuery(std.testing.allocator, std.testing.io, path.slice(), .{ .context = &gate, .queryFn = HeldCapacity.query });
    defer worker.destroy();
    defer gate.release();
    var cache: capacity.Cache = .{ .usage = .{ .total = 100, .free = 40 } };
    // The first refresh returns while the query remains held on another thread.
    for (0..100_000) |_| {
        _ = cache.refresh(worker, 1_000);
        if (cache.requested_at != null) break;
        try std.Thread.yield();
    }
    try std.testing.expectEqual(@as(?u64, 1_000), cache.requested_at);
    gate.waitEntered();
    try path.set("/changed-owner-buffer");
    for (0..100) |_| {
        try std.testing.expect(!cache.refresh(worker, 9_000));
        try std.testing.expectEqual(@as(u64, 100), cache.usage.?.total);
        try std.testing.expectError(error.Busy, worker.request());
    }
    // Owner calls must not wait even when the worker's slot mutex is held.
    {
        worker.mutex.lockUncancelable(worker.io);
        defer worker.mutex.unlock(worker.io);
        try std.testing.expect(!cache.refresh(worker, 9_000));
        try std.testing.expect(worker.takeCompletion() == null);
        try std.testing.expectError(error.Busy, worker.request());
    }
    gate.release();
    try refreshUntilIdle(&cache, worker, 1_001);
    try std.testing.expectEqual(@as(u64, 200), cache.usage.?.total);
    try std.testing.expectEqual(@as(u64, 80), cache.usage.?.free);
    try std.testing.expectEqualStrings("/owned-home", gate.path.slice());
    try std.testing.expectEqual(@as(usize, 1), gate.calls);
    try std.testing.expect(!cache.refresh(worker, 5_999));
    try std.testing.expectEqual(@as(usize, 1), gate.calls);

    gate.usage = null;
    for (0..100_000) |_| {
        _ = cache.refresh(worker, 6_000);
        if (cache.requested_at == 6_000) break;
        try std.Thread.yield();
    }
    try std.testing.expectEqual(@as(?u64, 6_000), cache.requested_at);
    try refreshUntilIdle(&cache, worker, 6_001);
    try std.testing.expectEqual(@as(usize, 2), gate.calls);
    // A failed refresh preserves the last good render result.
    try std.testing.expectEqual(@as(u64, 200), cache.usage.?.total);
}

test "capacity teardown finishes an accepted query and owns its path" {
    var gate: HeldCapacity = .{ .io = std.testing.io, .released = true };
    const worker = try capacity.Worker.createWithQuery(std.testing.allocator, std.testing.io, "/teardown-home", .{ .context = &gate, .queryFn = HeldCapacity.query });
    var destroyed = false;
    defer if (!destroyed) worker.destroy();
    for (0..100_000) |_| {
        worker.request() catch |err| switch (err) {
            error.Busy => {
                try std.Thread.yield();
                continue;
            },
            else => return err,
        };
        break;
    }
    worker.destroy();
    destroyed = true;
    try std.testing.expectEqual(@as(usize, 1), gate.calls);
    try std.testing.expectEqualStrings("/teardown-home", gate.path.slice());
}

const requests = @import("file_manager/requests.zig");

test "listing replacement closes old item menus while preserving selection identity" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    var first = [_]Files.Entry{ try testEntry("A"), try testEntry("B") };
    state.applyListing(&.{ .entries = &first });
    state.select(0);
    state.menu_mode = .context;
    state.menu_index = 0;
    var next = [_]Files.Entry{ first[1], first[0] };
    state.applyListing(&.{ .entries = &next });
    try std.testing.expectEqual(browser.MenuMode.none, state.menu_mode);
    try std.testing.expectEqualStrings("A", state.selectedItem().?.name());
    state.mode = .trash;
    var trash = [_]Files.TrashEntry{ try testTrashEntry("A-id"), try testTrashEntry("B-id") };
    state.applyTrashListing(&.{ .entries = &trash });
    state.menu_mode = .context;
    state.applyTrashListing(&.{ .entries = trash[1..] });
    try std.testing.expectEqual(browser.MenuMode.none, state.menu_mode);
}

test "filters cancel invisible selections and reject hidden file commands" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    var entries = [_]Files.Entry{ try testEntry("A"), try testEntry("B"), try testEntry(".hidden") };
    state.applyListing(&.{ .entries = &entries });
    state.select(0);
    state.menu_mode = .context;
    state.menu_index = 0;
    state.setQuery("B");
    try std.testing.expect(state.selected == null and state.selectedItem() == null);
    try std.testing.expectEqual(browser.MenuMode.none, state.menu_mode);
    try std.testing.expect(!state.stash(0, true));
    state.startDialog(.confirm_trash, 0, "A");
    try std.testing.expectEqual(browser.DialogKind.none, state.dialog.kind);
    state.startDialog(.rename, 0, "A");
    try std.testing.expectEqual(browser.DialogKind.none, state.dialog.kind);
    state.setQuery("");
    state.show_hidden = true;
    state.select(2);
    state.show_hidden = false;
    state.reconcileVisibility();
    try std.testing.expect(state.selected == null);
    // TextEntry writes the array directly; the same reconciliation boundary applies.
    state.select(0);
    try state.query.appendSlice(state.allocator, "B");
    state.reconcileVisibility();
    try std.testing.expect(state.selected == null);
}

test "paste completion only consumes the submitted cut clipboard version" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    var entries = [_]Files.Entry{ try testEntry("A"), try testEntry("B") };
    state.applyListing(&.{ .entries = &entries });
    try std.testing.expect(state.stash(0, true));
    const first = state.clipboard.?;
    const move: Files.Request = .{ .move = .{ .source = first.path, .destination = try Files.Text.init("/destination/A") } };
    state.completePaste(.{ .rename = .{ .path = first.path, .name = try Files.Text.init("new") } }, null);
    try std.testing.expect(state.clipboard != null);
    try std.testing.expect(state.stash(1, false));
    state.completePaste(move, first.revision);
    try std.testing.expectEqualStrings(entries[1].path.slice(), state.clipboard.?.path.slice());
    try std.testing.expect(state.stash(0, true));
    const latest = state.clipboard.?;
    state.completePaste(move, first.revision);
    try std.testing.expect(state.clipboard != null); // Same path, newer cut intent.
    state.completePaste(.{ .copy = .{ .source = latest.path, .destination = try Files.Text.init("/copy/A") } }, latest.revision);
    try std.testing.expect(state.clipboard != null);
    state.completePaste(move, latest.revision);
    try std.testing.expect(state.clipboard == null);
}

test "latest listing survives a full mutation queue and coalesces navigation" {
    var queue: requests.Queue = .{};
    defer queue.deinit(std.testing.allocator);
    for (0..requests.Queue.capacity) |i| try queue.enqueue(std.testing.allocator, .{ .request = .{ .stat = try Files.Text.init("/source") }, .kind = .stat, .paste_revision = i });
    try std.testing.expectError(error.Full, queue.enqueue(std.testing.allocator, .{ .request = .{ .stat = try Files.Text.init("/rejected") }, .kind = .stat }));
    for (1..65) |generation| try queue.enqueue(std.testing.allocator, .{ .request = .{ .scan = .{ .path = try Files.Text.init("/latest") } }, .kind = .scan, .listing_generation = generation });
    for (0..requests.Queue.capacity) |i| {
        try std.testing.expectEqual(i, queue.peek().?.paste_revision.?);
        try std.testing.expectEqual(i, queue.peek().?.paste_revision.?); // Busy must not consume.
        queue.pop();
    }
    try std.testing.expectEqual(@as(u64, 64), queue.peek().?.listing_generation);
    try std.testing.expectEqualStrings("/latest", queue.peek().?.request.scan.path.slice());
    queue.pop();
    try std.testing.expect(queue.peek() == null);
}

test "listing results match mode options and generation before adoption" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    try state.path.set("/folder");
    const scan: requests.Job = .{ .request = .{ .scan = .{ .path = state.path } }, .kind = .scan, .listing_generation = 7 };
    try std.testing.expect(scan.matchesListing(&state, 7));
    try std.testing.expect(!scan.matchesListing(&state, 8));
    state.mode = .trash;
    try std.testing.expect(!scan.matchesListing(&state, 7));
    const trash: requests.Job = .{ .request = .{ .list_trash = {} }, .kind = .trash_list, .listing_generation = 8 };
    try std.testing.expect(trash.matchesListing(&state, 8));
    state.mode = .browse;
    try std.testing.expect(!trash.matchesListing(&state, 8));
    state.sort = .size;
    try std.testing.expect(!scan.matchesListing(&state, 7));
    state.sort = .name;
    state.show_hidden = true;
    try std.testing.expect(!scan.matchesListing(&state, 7));
    state.show_hidden = false;
    state.descending = true;
    try std.testing.expect(!scan.matchesListing(&state, 7));
    state.descending = false;
    try state.path.set("/other");
    try std.testing.expect(!scan.matchesListing(&state, 7));
}

test "trash sorting preserves trash mode and selected trash id" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .trash;
    var entries = [_]Files.TrashEntry{ try testTrashEntry("A-id"), try testTrashEntry("B-id") };
    state.applyTrashListing(&.{ .entries = &entries });
    state.select(0);
    state.menu_mode = .context;
    state.descending = true;
    state.sortTrash();
    try std.testing.expectEqual(browser.Mode.trash, state.mode);
    try std.testing.expectEqualStrings("B-id", state.items.items[0].trash_id.slice());
    try std.testing.expectEqualStrings("A-id", state.selectedItem().?.trash_id.slice());
    try std.testing.expectEqual(browser.MenuMode.none, state.menu_mode);
}

test "listing retains skipped entry count without hiding valid siblings" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    var entries = [_]Files.Entry{try testEntry("valid")};
    state.applyListing(&.{ .entries = &entries, .skipped = 3 });
    try std.testing.expectEqual(@as(usize, 3), state.skipped);
    try std.testing.expectEqual(@as(usize, 1), state.visibleCount());
}

test "trash size and file type ordering match browse semantics" {
    var state = browser.State.init(std.testing.allocator);
    defer state.deinit();
    state.mode = .trash;
    try state.items.appendSlice(state.allocator, &.{
        .{ .label = try Files.Text.init("a.txt"), .size = 1 },
        .{ .label = try Files.Text.init("z.jpg"), .size = 4 },
        .{ .label = try Files.Text.init("directory"), .kind = .directory, .size = 0 },
    });
    state.sort = .size;
    state.descending = true;
    state.sortTrash();
    try std.testing.expectEqualStrings("z.jpg", state.items.items[0].name());
    try std.testing.expectEqualStrings("directory", state.items.items[2].name());
    state.sort = .type;
    state.descending = false;
    state.sortTrash();
    var previous: ?*const browser.Item = null;
    for (state.items.items) |*item| if (item.kind == .file) {
        if (previous) |prior| try std.testing.expectEqualStrings("z.jpg", prior.name());
        previous = item;
    };
    try std.testing.expectEqualStrings("a.txt", previous.?.name());
}
