//! Pure browser state. No DVUI and no file I/O: the application feeds results
//! in and the interface reads them, so everything here is unit-testable.
const std = @import("std");
const Files = @import("file_operations");

pub const Text = Files.Text;
pub const Sort = Files.Sort;

pub const View = enum { grid, list };
pub const Mode = enum { browse, trash };

pub const PlaceKind = enum { home, desktop, documents, downloads, pictures, music, videos, trash };
pub const Place = struct { kind: PlaceKind, path: Text = .{} };

pub const Item = struct {
    label: Text = .{},
    /// Absolute path in browse mode; original location in trash mode.
    path: Text = .{},
    /// Trash metadata id; empty outside the trash.
    trash_id: Text = .{},
    icon: Text = .{},
    kind: std.Io.File.Kind = .file,
    size: u64 = 0,
    modified: i96 = 0,
    launcher: bool = false,

    pub fn name(self: *const Item) []const u8 {
        return self.label.slice();
    }
};

pub const Clipboard = struct { path: Text, cut: bool = false, revision: u64 = 0 };

pub const History = struct {
    pub const capacity = 64;
    entries: [capacity]Text = @splat(.{}),
    count: usize = 0,
    index: usize = 0,

    pub fn reset(self: *History) void {
        self.count = 0;
        self.index = 0;
    }

    pub fn current(self: *const History) ?[]const u8 {
        if (self.count == 0) return null;
        return self.entries[self.index].slice();
    }

    pub fn push(self: *History, path: []const u8) !void {
        if (self.count != 0 and std.mem.eql(u8, self.entries[self.index].slice(), path)) return;
        if (self.count == 0) {
            self.entries[0] = try Text.init(path);
            self.index = 0;
            self.count = 1;
            return;
        }
        if (self.count == capacity) {
            @memmove(self.entries[0 .. capacity - 1], self.entries[1..capacity]);
            self.count = capacity - 1;
            if (self.index != 0) self.index -= 1;
        }
        const at = self.index + 1;
        self.entries[at] = try Text.init(path);
        self.index = at;
        self.count = at + 1;
    }

    pub fn back(self: *History) ?[]const u8 {
        if (self.index == 0) return null;
        self.index -= 1;
        return self.entries[self.index].slice();
    }

    pub fn forward(self: *History) ?[]const u8 {
        if (self.index + 1 >= self.count) return null;
        self.index += 1;
        return self.entries[self.index].slice();
    }
};

pub const MenuMode = enum { none, context, sort };

pub const DialogKind = enum { none, new_folder, rename, confirm_trash, confirm_delete, confirm_empty, properties };

pub const Properties = struct {
    name: Text = .{},
    path: Text = .{},
    kind: std.Io.File.Kind = .file,
    size: u64 = 0,
    modified: i96 = 0,
    permissions: u32 = 0,
    inode: u64 = 0,
    links: u64 = 0,
};

pub const Dialog = struct {
    kind: DialogKind = .none,
    /// Owned snapshot captured when the dialog opens, before async listings land.
    request: ?Files.Request = null,
    text: std.ArrayList(u8) = .empty,
    properties: Properties = .{},
};

pub const State = struct {
    allocator: std.mem.Allocator,
    home: Text = .{},
    places: [8]?Place = @splat(null),
    mode: Mode = .browse,
    view: View = .grid,
    sort: Sort = .name,
    descending: bool = false,
    show_hidden: bool = false,
    path: Text = .{},
    history: History = .{},
    items: std.ArrayList(Item) = .empty,
    selected: ?usize = null,
    truncated: bool = false,
    skipped: usize = 0,
    query: std.ArrayList(u8) = .empty,
    clipboard: ?Clipboard = null,
    clipboard_revision: u64 = 0,
    dialog: Dialog = .{},
    menu_mode: MenuMode = .none,
    menu_at: [2]f32 = .{ 0, 0 },
    menu_index: usize = 0,
    toast: [160]u8 = @splat(0),
    toast_len: usize = 0,
    toast_until: u64 = 0,
    loading: bool = false,
    last_click_ms: u64 = 0,
    last_click_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        self.items.deinit(self.allocator);
        self.query.deinit(self.allocator);
        self.dialog.text.deinit(self.allocator);
    }

    pub fn addPlace(self: *State, kind: PlaceKind, path: []const u8) void {
        for (&self.places) |*slot| {
            if (slot.* != null) continue;
            slot.* = .{ .kind = kind, .path = Text.init(path) catch return };
            return;
        }
    }

    pub fn querySlice(self: *const State) []const u8 {
        return self.query.items;
    }

    pub fn setQuery(self: *State, bytes: []const u8) void {
        self.query.clearRetainingCapacity();
        self.query.appendSlice(self.allocator, bytes) catch {};
        self.reconcileVisibility();
    }

    pub fn actionable(self: *const State, index: usize) bool {
        return index < self.items.items.len and self.visible(&self.items.items[index]);
    }

    /// TextEntry edits query in place, so call this after edits as well as imports.
    pub fn reconcileVisibility(self: *State) void {
        if (self.selected) |index| if (!self.actionable(index)) {
            self.selected = null;
        };
        if (self.menu_mode == .context and !self.actionable(self.menu_index)) self.menu_mode = .none;
    }

    pub fn visible(self: *const State, item: *const Item) bool {
        const name = item.label.slice();
        if (!self.show_hidden and name.len != 0 and name[0] == '.') return false;
        const query = self.querySlice();
        if (query.len == 0) return true;
        return containsIgnoreCase(name, query);
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var index: usize = 0;
        while (index + needle.len <= haystack.len) : (index += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
        }
        return false;
    }

    pub fn visibleCount(self: *const State) usize {
        var count: usize = 0;
        for (self.items.items) |*item| if (self.visible(item)) {
            count += 1;
        };
        return count;
    }

    pub fn visibleAt(self: *const State, ordinal: usize) ?usize {
        var seen: usize = 0;
        for (self.items.items, 0..) |*item, index| {
            if (!self.visible(item)) continue;
            if (seen == ordinal) return index;
            seen += 1;
        }
        return null;
    }

    pub fn selectedItem(self: *const State) ?*const Item {
        const index = self.selected orelse return null;
        if (!self.actionable(index)) return null;
        return &self.items.items[index];
    }

    pub fn select(self: *State, index: ?usize) void {
        self.selected = if (index) |value| if (self.actionable(value)) value else null else null;
    }

    pub fn notify(self: *State, now_ms: u64, message: []const u8) void {
        const count = @min(message.len, self.toast.len);
        @memcpy(self.toast[0..count], message[0..count]);
        self.toast_len = count;
        self.toast_until = now_ms + 4000;
    }

    pub fn toastText(self: *const State, now_ms: u64) []const u8 {
        if (self.toast_until <= now_ms) return "";
        return self.toast[0..self.toast_len];
    }

    pub fn startDialog(self: *State, kind: DialogKind, index: usize, prefill: []const u8) void {
        self.dialog.request = switch (kind) {
            .new_folder => if (self.mode == .browse) .{ .create_directory = .{ .parent = self.path, .name = .{} } } else null,
            .rename, .confirm_trash => if (self.mode == .browse and self.actionable(index) and self.items.items[index].trash_id.len == 0)
                if (kind == .rename) .{ .rename = .{ .path = self.items.items[index].path, .name = .{} } } else .{ .trash = self.items.items[index].path }
            else
                null,
            .confirm_delete => if (self.mode == .trash and self.actionable(index) and self.items.items[index].trash_id.len != 0)
                .{ .delete_trash = .{ .id = self.items.items[index].trash_id, .confirmed = true } }
            else
                null,
            .confirm_empty => if (self.mode == .trash) .{ .empty_trash = .{ .confirmed = true } } else null,
            else => null,
        };
        switch (kind) {
            .rename, .confirm_trash, .confirm_delete => if (self.dialog.request == null) return,
            else => {},
        }
        self.dialog.kind = kind;
        self.dialog.text.clearRetainingCapacity();
        self.dialog.text.appendSlice(self.allocator, prefill) catch {};
        self.menu_mode = .none;
    }

    /// Returns the captured request, never an index into a replacement listing.
    pub fn confirmDialog(self: *State, name: Text) ?Files.Request {
        var request = self.dialog.request orelse return null;
        switch (request) {
            .rename => |*value| value.name = name,
            .create_directory => |*value| value.name = name,
            else => {},
        }
        self.closeDialog();
        return request;
    }

    pub fn closeDialog(self: *State) void {
        self.dialog.kind = .none;
        self.dialog.request = null;
        self.dialog.text.clearRetainingCapacity();
    }

    pub fn canStash(self: *const State, index: usize) bool {
        return self.mode == .browse and self.actionable(index) and self.items.items[index].trash_id.len == 0;
    }

    /// Trash paths describe the original live location, not the trashed object.
    pub fn stash(self: *State, index: usize, cut: bool) bool {
        if (!self.canStash(index)) return false;
        self.clipboard_revision +%= 1;
        self.clipboard = .{ .path = self.items.items[index].path, .cut = cut, .revision = self.clipboard_revision };
        return true;
    }

    pub fn completePaste(self: *State, request: Files.Request, revision: ?u64) void {
        const expected = revision orelse return;
        const clip = self.clipboard orelse return;
        if (!clip.cut or clip.revision != expected) return;
        switch (request) {
            .move => |move| if (std.mem.eql(u8, clip.path.slice(), move.source.slice())) {
                self.clipboard = null;
            },
            else => {},
        }
    }

    pub fn applyListing(self: *State, listing: *const Files.Listing) void {
        if (self.menu_mode == .context) self.menu_mode = .none;
        self.last_click_ms = 0;
        var keep: ?Text = null;
        if (self.selected) |index| if (index < self.items.items.len) {
            keep = self.items.items[index].path;
        };
        self.items.clearRetainingCapacity();
        for (listing.entries) |entry| {
            var item: Item = .{ .label = entry.name, .path = entry.path, .kind = entry.kind, .size = entry.size, .modified = entry.modified };
            if (entry.desktop) |desktop| {
                if (desktop.icon) |icon| item.icon = Text.init(icon) catch .{};
                item.launcher = desktop.kind == .application;
            }
            self.items.append(self.allocator, item) catch break;
        }
        self.truncated = listing.truncated;
        self.skipped = listing.skipped;
        self.selected = null;
        if (keep) |path| for (self.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.path.slice(), path.slice())) {
                self.selected = index;
                break;
            }
        };
        self.reconcileVisibility();
        self.loading = false;
    }

    pub fn applyTrashListing(self: *State, listing: *const Files.TrashListing) void {
        if (self.menu_mode == .context) self.menu_mode = .none;
        self.last_click_ms = 0;
        self.items.clearRetainingCapacity();
        for (listing.entries) |entry| {
            self.items.append(self.allocator, .{
                .label = entry.name,
                .path = entry.original_path,
                .trash_id = entry.id,
                .kind = entry.kind,
                .size = entry.size,
                .modified = entry.modified,
            }) catch break;
        }
        self.truncated = listing.truncated;
        self.skipped = 0;
        self.selected = null;
        self.sortTrash();
        self.loading = false;
    }

    /// Trash keeps its identity/mode; sorting never schedules a browse scan.
    pub fn sortTrash(self: *State) void {
        const keep = if (self.selectedItem()) |item| item.trash_id else null;
        self.menu_mode = .none;
        self.last_click_ms = 0;
        std.mem.sort(Item, self.items.items, self, lessThan);
        self.selected = null;
        if (keep) |id| for (self.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, id.slice(), item.trash_id.slice())) {
                self.select(index);
                break;
            }
        };
        self.reconcileVisibility();
    }

    fn lessThan(self: *const State, a: Item, b: Item) bool {
        var order = switch (self.sort) {
            .name => std.mem.order(u8, a.name(), b.name()),
            .size => std.math.order(a.size, b.size),
            .modified => std.math.order(a.modified, b.modified),
            .type => if (a.kind != b.kind) std.math.order(@backingInt(a.kind), @backingInt(b.kind)) else std.mem.order(u8, std.fs.path.extension(a.name()), std.fs.path.extension(b.name())),
        };
        if (order == .eq) order = std.mem.order(u8, a.name(), b.name());
        return if (self.descending) order == .gt else order == .lt;
    }

    pub fn applyProperties(self: *State, properties: Files.Properties, display_name: []const u8) void {
        self.dialog.kind = .properties;
        self.dialog.properties = .{
            .name = Text.init(display_name) catch .{},
            .path = properties.entry.path,
            .kind = properties.entry.kind,
            .size = properties.entry.size,
            .modified = properties.entry.modified,
            .permissions = properties.permissions,
            .inode = @intCast(properties.inode),
            .links = @intCast(properties.link_count),
        };
    }

    pub fn kindLabel(kind: std.Io.File.Kind) []const u8 {
        return switch (kind) {
            .directory => "文件夹",
            .sym_link => "链接",
            .block_device => "块设备",
            .character_device => "字符设备",
            .named_pipe => "管道",
            .unix_domain_socket => "套接字",
            else => "文件",
        };
    }
};
