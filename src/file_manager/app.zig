//! zfiler application: the window, the frame loop, and request dispatch.
//! The interface stays pure; every side effect crosses a command or a worker job.
const std = @import("std");
const capacity = @import("capacity_worker.zig");
const dvui = @import("dvui");
const views = @import("views");
const Files = @import("file_operations");
const files_worker = @import("file_operations").worker;
const icons = @import("system_icons");
const Theme = @import("nalume_ui").theme;
const Design = @import("nalume_ui").design;
const Fonts = @import("nalume_ui").fonts.Fonts;
const browser = @import("state.zig");
const ui = @import("ui.zig");

const requests = @import("requests.zig");
const Kind = requests.Kind;
const Job = requests.Job;
const Pending = requests.Pending;
pub fn run(init: std.process.Init) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const app = try App.create(debug.allocator(), init);
    defer app.destroy();
    try app.loop();
}

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    manager: views.Manager,
    view: *views.View = undefined,
    fonts: *Fonts = undefined,
    icon_service: *icons.Service = undefined,
    worker: *files_worker.Worker = undefined,
    state: browser.State,
    queue: requests.Queue = .{},
    listing_generation: u64 = 0,
    pending: ?Pending = null,
    next_id: u64 = 1,
    quit: bool = false,
    capacity_worker: *capacity.Worker = undefined,
    disk_cache: capacity.Cache = .{},

    fn create(gpa: std.mem.Allocator, init: std.process.Init) !*App {
        const app = try gpa.create(App);
        errdefer gpa.destroy(app);
        app.* = .{
            .gpa = gpa,
            .io = init.io,
            .manager = try views.Manager.connect(gpa, init.io, null),
            .state = browser.State.init(gpa),
        };
        errdefer app.manager.deinit();
        errdefer app.state.deinit();

        app.fonts = try Fonts.create(gpa, init.io, init.environ_map, "zfiler");
        errdefer app.fonts.destroy();
        app.manager.font_hooks = app.fonts.hooks();

        app.icon_service = try icons.Service.create(gpa, init.io, .{});
        errdefer app.icon_service.destroy();

        const home = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
        app.capacity_worker = try capacity.Worker.create(gpa, init.io, home);
        errdefer app.capacity_worker.destroy();
        app.worker = try files_worker.Worker.create(gpa, init.io, .{
            .home = home,
            .xdg_data_home = init.environ_map.get("XDG_DATA_HOME"),
            .locale = init.environ_map.get("LC_ALL") orelse init.environ_map.get("LANG"),
            .path = init.environ_map.get("PATH"),
            .terminal = init.environ_map.get("TERMINAL"),
        });
        errdefer if (app.worker.destroy()) |completion| {
            var final = completion;
            final.deinit();
        };

        try app.state.home.set(home);
        app.state.addPlace(.home, home);
        const quick = [_]struct { kind: browser.PlaceKind, name: []const u8 }{
            .{ .kind = .desktop, .name = "Desktop" },
            .{ .kind = .documents, .name = "Documents" },
            .{ .kind = .downloads, .name = "Downloads" },
            .{ .kind = .pictures, .name = "Pictures" },
            .{ .kind = .music, .name = "Music" },
            .{ .kind = .videos, .name = "Videos" },
        };
        var buffer: [4096]u8 = undefined;
        for (quick) |entry| {
            const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ home, entry.name }) catch continue;
            _ = std.Io.Dir.cwd().statFile(init.io, path, .{}) catch continue;
            app.state.addPlace(entry.kind, path);
        }
        app.state.addPlace(.trash, "trash:///");

        app.view = try app.manager.createWindow(.{
            .title = "文件管理器",
            .app_id = "dev.nalume.zfiler",
            .width = 1080,
            .height = 720,
        });
        errdefer app.view.deinit();

        try app.state.path.set(home);
        app.state.history.push(home) catch {};
        app.requestScan();
        return app;
    }
    fn destroy(self: *App) void {
        // Views must go first: destroying one releases its font lease.
        if (self.manager.hasView(self.view)) self.view.deinit();
        self.manager.deinit();
        self.fonts.destroy();
        self.icon_service.destroy();
        self.capacity_worker.destroy();
        if (self.worker.destroy()) |completion| {
            var final = completion;
            final.deinit();
        }
        self.queue.deinit(self.gpa);
        self.state.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn loop(self: *App) !void {
        while (!self.quit and self.view.isOpen()) {
            try self.manager.dispatchWithTimeout(120);
            if (!self.view.isOpen()) break;
            self.pumpRequests();
            if (self.fonts.poll(self.view)) self.view.dvui_view.extra_frames_needed = @max(1, self.view.dvui_view.extra_frames_needed);
            if (self.disk_cache.refresh(self.capacity_worker, nowMs()))
                self.view.dvui_view.extra_frames_needed = @max(1, self.view.dvui_view.extra_frames_needed);
            // An in-flight icon decode needs more frames even without input.
            if (self.icon_service.busy() or self.fonts.busy()) self.view.dvui_view.extra_frames_needed = @max(1, self.view.dvui_view.extra_frames_needed);
            if (self.view.renderReady()) try self.renderFrame();
        }
    }

    fn renderFrame(self: *App) !void {
        const now = nowMs();
        const icons_changed = self.icon_service.poll(now);
        try self.view.begin();
        Theme.install(.{}, false);
        self.fonts.applyTheme();
        const action = ui.render(&self.state, .{
            .icons = self.icon_service,
            .scale = iconScale(self.view.backend.scaling.scale),
            .now_ms = now,
            .disk = self.disk_cache.usage,
            .allocator = self.gpa,
            .font_message = self.fonts.status(),
        });
        try self.view.end();
        if (icons_changed) self.view.dvui_view.extra_frames_needed = @max(1, self.view.dvui_view.extra_frames_needed);
        if (action) |value| self.apply(value);
    }
    /// Queue visible icons and paint immediately; polling happens once per frame.
    fn warmIcons(self: *App) void {
        const scale = iconScale(self.view.backend.scaling.scale);
        const logical = ui.iconLogical(self.state.view);
        var requested: usize = 0;
        for (self.state.items.items) |*item| {
            if (requested == 48) break;
            if (!self.state.visible(item)) continue;
            _ = self.icon_service.get(ui.iconKey(item, logical, scale));
            requested += 1;
        }
    }

    fn apply(self: *App, action: ui.Action) void {
        switch (action) {
            .navigate => |path| self.navigate(path.slice()),
            .open => |index| self.openIndex(index),
            .open_trash => self.requestTrash(),
            .back => if (self.state.history.back()) |path| self.restorePath(path),
            .forward => if (self.state.history.forward()) |path| self.restorePath(path),
            .up => {
                if (self.state.mode == .trash) {
                    self.navigate(self.state.home.slice());
                    return;
                }
                const parent = std.fs.path.dirname(self.state.path.slice()) orelse return;
                self.navigate(parent);
            },
            .refresh => self.refresh(),
            .set_sort => |sort| {
                self.state.sort = sort;
                self.state.menu_mode = .none;
                if (self.state.mode == .trash) self.state.sortTrash() else self.requestScan();
            },
            .toggle_hidden => {
                self.state.show_hidden = !self.state.show_hidden;
                self.state.menu_mode = .none;
                self.state.reconcileVisibility();
                if (self.state.mode == .browse) self.requestScan();
            },
            .confirmed => |request| {
                self.state.menu_mode = .none;
                switch (request) {
                    .create_directory => |value| {
                        const name = value.name.slice();
                        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) {
                            self.state.notify(nowMs(), "名称无效");
                            return;
                        }
                        self.submit(request, .mutate, "已新建文件夹");
                    },
                    .rename => |value| {
                        if (value.name.len == 0) return;
                        self.submit(request, .mutate, "已重命名");
                    },
                    .trash => self.submit(request, .mutate, "已移到回收站"),
                    .delete_trash => self.submit(request, .delete_trash, "已彻底删除"),
                    .empty_trash => self.submit(request, .empty_trash, "已清空回收站"),
                    else => {},
                }
            },
            .restore => |index| self.restoreIndex(index),
            .empty_trash => self.submit(.{ .empty_trash = .{ .confirmed = true } }, .empty_trash, "已清空回收站"),
            .properties => |index| self.properties(index),
            .copy => |index| self.stash(index, false),
            .cut => |index| self.stash(index, true),
            .paste => self.paste(),
            .close_menu => self.state.menu_mode = .none,
        }
    }

    fn setPath(self: *App, path: []const u8) !void {
        if (path.len >= 4096) return error.PathTooLong;
        var copy: [4096]u8 = undefined;
        @memcpy(copy[0..path.len], path);
        try self.state.path.set(copy[0..path.len]);
        self.state.mode = .browse;
        self.state.setQuery("");
        self.state.selected = null;
        self.state.items.clearRetainingCapacity();
        self.state.menu_mode = .none;
    }

    fn navigate(self: *App, path: []const u8) void {
        if (self.state.mode == .browse and std.mem.eql(u8, path, self.state.path.slice())) {
            self.requestScan();
            return;
        }
        self.setPath(path) catch {
            self.state.notify(nowMs(), "路径过长");
            return;
        };
        self.state.history.push(path) catch {};
        self.requestScan();
    }

    fn restorePath(self: *App, path: []const u8) void {
        self.setPath(path) catch return;
        self.requestScan();
    }

    fn requestScan(self: *App) void {
        if (self.state.mode != .browse) return;
        self.listing_generation +%= 1;
        self.state.loading = true;
        self.submitJob(.{ .request = .{ .scan = .{
            .path = self.state.path,
            .show_hidden = self.state.show_hidden,
            .sort = self.state.sort,
            .descending = self.state.descending,
        } }, .kind = .scan, .listing_generation = self.listing_generation });
    }

    fn requestTrash(self: *App) void {
        if (self.state.mode != .trash) {
            self.state.items.clearRetainingCapacity();
            self.state.setQuery("");
        }
        self.state.mode = .trash;
        self.listing_generation +%= 1;
        self.state.loading = true;
        self.state.selected = null;
        self.state.menu_mode = .none;
        self.submitJob(.{ .request = .{ .list_trash = {} }, .kind = .trash_list, .listing_generation = self.listing_generation });
    }

    fn refresh(self: *App) void {
        if (self.state.mode == .trash) self.requestTrash() else self.requestScan();
    }

    fn openIndex(self: *App, index: usize) void {
        if (!self.state.actionable(index)) return;
        const item = self.state.items.items[index];
        if (self.state.mode == .trash) {
            self.restoreIndex(index);
            return;
        }
        if (item.kind == .directory) {
            self.navigate(item.path.slice());
            return;
        }
        self.submit(.{ .open = item.path }, .open, "");
    }

    fn stash(self: *App, index: usize, cut: bool) void {
        if (!self.state.stash(index, cut)) return;
        self.state.menu_mode = .none;
        self.state.notify(nowMs(), if (cut) "已剪切" else "已复制");
    }

    fn paste(self: *App) void {
        const clip = self.state.clipboard orelse {
            self.state.notify(nowMs(), "剪贴板为空");
            return;
        };
        if (self.state.mode != .browse) {
            self.state.notify(nowMs(), "回收站中不能粘贴");
            return;
        }
        var buffer: [4096]u8 = undefined;
        const base = std.fs.path.basename(clip.path.slice());
        const destination = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ self.state.path.slice(), base }) catch {
            self.state.notify(nowMs(), "路径过长");
            return;
        };
        const target = Files.Text.init(destination) catch {
            self.state.notify(nowMs(), "路径过长");
            return;
        };
        const request: Files.Request = if (clip.cut)
            .{ .move = .{ .source = clip.path, .destination = target } }
        else
            .{ .copy = .{ .source = clip.path, .destination = target } };
        self.submitJob(.{ .request = request, .kind = .mutate, .note = if (clip.cut) "已移动" else "已复制", .paste_revision = clip.revision });
    }

    fn restoreIndex(self: *App, index: usize) void {
        if (!self.state.actionable(index)) return;
        self.state.menu_mode = .none;
        self.submit(.{ .restore = .{ .id = self.state.items.items[index].trash_id } }, .restore, "已还原");
    }

    fn properties(self: *App, index: usize) void {
        if (!self.state.actionable(index)) return;
        self.state.menu_mode = .none;
        if (self.state.mode == .trash) {
            self.state.notify(nowMs(), "回收站项目暂不支持属性");
            return;
        }
        self.submit(.{ .stat = self.state.items.items[index].path }, .stat, "");
    }

    fn submit(self: *App, request: Files.Request, kind: Kind, note: []const u8) void {
        self.submitJob(.{ .request = request, .kind = kind, .note = note });
    }
    fn submitJob(self: *App, job: Job) void {
        if (self.pending != null or self.queue.peek() != null) {
            self.enqueue(job);
            return;
        }
        self.worker.submit(self.next_id, job.request) catch |err| {
            if (err == error.Busy) self.enqueue(job) else self.submissionFailed(job);
            return;
        };
        self.pending = .{ .id = self.next_id, .job = job };
        self.next_id +%= 1;
    }
    fn enqueue(self: *App, job: Job) void {
        self.queue.enqueue(self.gpa, job) catch {
            self.state.notify(nowMs(), "操作过多，请稍后重试");
        };
    }
    fn submissionFailed(self: *App, job: Job) void {
        if (job.isListing()) {
            if (!job.matchesListing(&self.state, self.listing_generation)) return;
            self.state.loading = false;
        }
        self.state.notify(nowMs(), "文件服务不可用");
    }
    fn pumpRequests(self: *App) void {
        while (self.worker.takeCompletion()) |completion_value| {
            var completion = completion_value;
            defer completion.deinit();
            const pending = self.pending orelse continue;
            if (completion.id != pending.id) continue;
            self.pending = null;
            self.applyCompletion(pending, &completion);
        }
        if (self.pending != null) return;
        const job = self.queue.peek() orelse return;
        self.worker.submit(self.next_id, job.request) catch |err| {
            if (err != error.Busy) {
                self.queue.pop();
                self.submissionFailed(job);
            }
            return;
        };
        self.queue.pop();
        self.pending = .{ .id = self.next_id, .job = job };
        self.next_id +%= 1;
    }
    fn applyCompletion(self: *App, pending: Pending, completion: *files_worker.Completion) void {
        const job = pending.job;
        // Old successes and failures cannot alter a newer mode, sort or location.
        if (job.isListing() and !job.matchesListing(&self.state, self.listing_generation)) return;
        const now = nowMs();
        if ((completion.error_kind orelse if (completion.error_code) |code| Files.classify(code) else null)) |kind| {
            if (job.isListing()) self.state.loading = false;
            self.state.notify(now, errorMessage(kind));
            return;
        }
        const result = completion.result orelse return;
        switch (result) {
            .listing => |listing| {
                if (job.kind != .scan) return;
                self.state.applyListing(&listing);
                self.warmIcons();
            },
            .trash_listing => |listing| {
                if (job.kind != .trash_list) return;
                self.state.applyTrashListing(&listing);
                self.warmIcons();
            },
            .properties => |props| {
                if (self.state.dialog.kind != .none) return;
                self.state.applyProperties(props, std.fs.path.basename(props.entry.path.slice()));
            },
            .empty_report => |report| {
                var buffer: [160]u8 = undefined;
                const message = if (report.failed != 0)
                    std.fmt.bufPrint(&buffer, "已删除 {d} 项，{d} 项失败：{s}", .{ report.deleted, report.failed, if (report.last_error) |err| errorMessage(Files.classify(err)) else "操作失败" }) catch "部分项目删除失败"
                else
                    std.fmt.bufPrint(&buffer, "已清空回收站：{d} 项", .{report.deleted}) catch "已清空回收站";
                self.state.notify(now, message);
                self.refresh();
            },
            .trashed => {
                if (job.note.len != 0) self.state.notify(now, job.note);
                self.refresh();
            },
            .restored_cleanup_failed => {
                self.state.notify(now, "已还原，但回收站记录清理失败");
                self.refresh();
            },
            .done => switch (job.kind) {
                .open, .stat => {},
                .mutate => {
                    self.state.completePaste(job.request, job.paste_revision);
                    if (job.note.len != 0) self.state.notify(now, job.note);
                    self.refresh();
                },
                .restore, .delete_trash, .empty_trash => {
                    if (job.note.len != 0) self.state.notify(now, job.note);
                    self.refresh();
                },
                else => self.refresh(),
            },
        }
    }
};

fn nowMs() u64 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &time) != 0) return 0;
    return @as(u64, @intCast(time.sec)) * 1000 + @as(u64, @intCast(time.nsec)) / std.time.ns_per_ms;
}

fn iconScale(raw: f32) u32 {
    const rounded = @round(raw);
    if (!(rounded > 0)) return 1;
    return @intFromFloat(@min(rounded, 8));
}

fn errorMessage(kind: Files.ErrorKind) []const u8 {
    return switch (kind) {
        .invalid_path => "路径无效",
        .invalid_utf8 => "文件名编码无效",
        .path_too_long => "路径过长",
        .not_found => "文件或目录不存在",
        .permission_denied => "没有访问权限",
        .not_directory => "不是文件夹",
        .name_conflict => "同名文件已存在",
        .cross_device_unsupported => "不支持跨设备操作",
        .unsupported => "不支持此操作",
        .invalid_desktop_entry => "桌面启动项无效",
        .launcher_unavailable => "无法启动程序",
        .terminal_unavailable => "找不到终端",
        .confirmation_required => "需要确认",
        .invalid_trash_info => "回收站记录已损坏",
        .trash_unavailable => "回收站不可用",
        .resource_limit => "资源不足",
        .no_space => "磁盘空间不足",
        .busy => "文件忙，请稍后重试",
        .io_failure => "操作失败",
    };
}
