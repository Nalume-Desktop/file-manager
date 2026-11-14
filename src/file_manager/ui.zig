//! zfiler interface: one immediate-mode frame over the pure browser state.
//! Rendering performs no I/O; it returns at most one command per frame.
const std = @import("std");
const dvui = @import("dvui");
const Design = @import("nalume_ui").design;
const Theme = @import("nalume_ui").theme;
const Components = @import("nalume_ui").components;
const Files = @import("file_operations");
const icons = @import("system_icons");
const browser = @import("state.zig");

const C = &Theme.colors;
const radii = &Theme.radii;

const sidebar_width: f32 = 204;
const window_padding: f32 = 24;
const card_gap: f32 = 16;
const content_padding: f32 = 16;
const content_gap: f32 = 12;
const sidebar_padding: f32 = 12;
const toolbar_height: f32 = 36;
const stats_height: f32 = 24;
const status_height: f32 = 24;
const nav_size: f32 = 32;
const tile_width: f32 = 120;
const tile_height: f32 = 100;
const tile_gap: f32 = 12;
const kind_width: f32 = 90;
const size_width: f32 = 88;
const time_width: f32 = 150;
const cell_gap: f32 = 12;
var search_focus_id: ?dvui.Id = null;
var search_open: bool = false;

pub const Action = union(enum) {
    navigate: Files.Text,
    open: usize,
    open_trash,
    back,
    forward,
    up,
    refresh,
    set_sort: Files.Sort,
    toggle_hidden,
    /// Dialog confirmations already own their path or Trash ID.
    confirmed: Files.Request,
    restore: usize,
    empty_trash,
    properties: usize,
    copy: usize,
    cut: usize,
    paste,
    close_menu,
};

pub const DiskUsage = @import("capacity_worker.zig").Usage;

pub const Frame = struct {
    icons: *icons.Service,
    scale: u32,
    now_ms: u64,
    allocator: std.mem.Allocator,
    font_message: ?[]const u8 = null,
    disk: ?DiskUsage = null,
};

pub fn render(state: *browser.State, frame: Frame) ?Action {
    state.reconcileVisibility();
    var action: ?Action = null;
    {
        var root = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 1,
            .expand = .both,
            .padding = .all(window_padding),
            .margin = .{},
            .background = true,
            .color_fill = .{ .color = C.background },
            .role = .none,
        });
        defer root.deinit();
        renderSidebar(state, frame, &action);
        renderContent(state, frame, &action);
    }
    renderMenu(state, frame, &action);
    renderDialog(state, frame, &action);
    if (keyboard(state, frame)) |value| action = value;
    return action;
}

fn text(src: std.builtin.SourceLocation, str: []const u8, color: dvui.Color, opts: dvui.Options) void {
    Components.text(src, str, color, opts);
}

fn textAligned(src: std.builtin.SourceLocation, str: []const u8, color: dvui.Color, align_x: f32, opts: dvui.Options) void {
    dvui.labelNoFmt(src, str, .{ .align_x = align_x, .align_y = 0.5 }, opts.override(.{ .font = opts.font orelse dvui.Font.theme(.body), .padding = opts.padding orelse .{}, .color_text = .{ .color = color } }));
}

fn bodyFont() dvui.Font {
    return dvui.Font.theme(.body);
}

/// Design稿字号是 em 像素；DVUI 的 Font.size 是"大写 M 高"，
/// 同一数值会渲染得更大。按 0.78 折算到 DVUI 尺寸。
fn fs(px: f32) f32 {
    return px * 0.78;
}

// ---------------------------------------------------------------- sidebar

fn renderSidebar(state: *browser.State, frame: Frame, action: *?Action) void {
    var side = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 10,
        .min_size_content = .{ .w = sidebar_width },
        .max_size_content = .width(sidebar_width),
        .expand = .vertical,
        .padding = .all(sidebar_padding),
        .margin = .{ .w = card_gap },
        .background = true,
        .color_fill = .{ .color = C.surface },
        .corners = .all(radii.surface),
        .role = .none,
    });
    defer side.deinit();

    sectionLabel(@src(), "快速访问", 11);
    var ordinal: usize = 0;
    for (&state.places) |*slot| {
        const place = slot.* orelse continue;
        if (place.kind == .trash) continue;
        var place_value = place;
        const selected = state.mode == .browse and std.mem.eql(u8, place.path.slice(), state.path.slice());
        if (placeRow(&place_value, placeLabel(place_value.kind), placeIcon(place_value.kind), selected, ordinal + 12)) {
            if (Files.Text.init(place.path.slice())) |path| {
                action.* = .{ .navigate = path };
            } else |_| {}
        }
        ordinal += 1;
    }
    dividerRow(@src(), 30);
    sectionLabel(@src(), "位置", 31);
    for (&state.places) |*slot| {
        const place = slot.* orelse continue;
        if (place.kind != .trash) continue;
        var place_value = place;
        if (placeRow(&place_value, "回收站", dvui.entypo.trash, state.mode == .trash, 40)) action.* = .open_trash;
    }
    storageBlock(state, frame);
}

fn sectionLabel(src: std.builtin.SourceLocation, label: []const u8, id: usize) void {
    text(src, label, C.muted, .{ .id_extra = id, .min_size_content = .{ .h = 24 }, .padding = .{ .x = 10, .w = 10 }, .margin = .{ .h = 1 }, .font = bodyFont().withSize(fs(12)).withWeight(.bold) });
}

fn dividerRow(src: std.builtin.SourceLocation, id: usize) void {
    var wrap = dvui.box(src, .{ .dir = .vertical }, .{ .id_extra = id, .expand = .horizontal, .padding = .{ .y = 4 }, .margin = .{}, .role = .none });
    defer wrap.deinit();
    var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .min_size_content = .{ .h = 1 }, .max_size_content = .height(1), .padding = .{}, .margin = .{}, .background = true, .color_fill = .{ .color = C.divider }, .role = .none });
    line.deinit();
}

fn storageBlock(state: *browser.State, frame: Frame) void {
    _ = state;
    const disk = frame.disk orelse return;
    if (disk.total == 0) return;
    const used = if (disk.total > disk.free) disk.total - disk.free else 0;
    const fraction: f32 = @min(1.0, @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(disk.total)));
    var block = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = 60, .expand = .horizontal, .gravity_y = 1.0, .padding = .all(10), .margin = .{ .h = 2 }, .role = .none });
    defer block.deinit();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 61, .expand = .horizontal, .min_size_content = .{ .h = 18 }, .padding = .{}, .margin = .{}, .role = .none });
        defer row.deinit();
        text(@src(), "系统盘", C.muted, .{ .id_extra = 62, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(13)) });
        var percent_buffer: [16]u8 = undefined;
        const percent = std.fmt.bufPrint(&percent_buffer, "{d}% 已用", .{@as(u32, @intFromFloat(@round(fraction * 100.0)))}) catch "";
        text(@src(), percent, C.muted, .{ .id_extra = 63, .gravity_x = 1.0, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(12)) });
    }
    const bar_width: f32 = sidebar_width - sidebar_padding * 2 - 20;
    {
        var track = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 64, .min_size_content = .{ .w = bar_width, .h = 4 }, .max_size_content = .{ .w = bar_width, .h = 4 }, .padding = .{}, .margin = .{ .y = 4 }, .background = true, .color_fill = .{ .color = C.track }, .corners = .all(2), .role = .none });
        defer track.deinit();
        const filled = @max(2.0, bar_width * fraction);
        var fill = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 65, .min_size_content = .{ .w = filled, .h = 4 }, .max_size_content = .{ .w = filled, .h = 4 }, .padding = .{}, .margin = .{}, .background = true, .color_fill = .{ .color = C.accent }, .corners = .all(2), .role = .none });
        fill.deinit();
    }
    var detail_buffer: [72]u8 = undefined;
    var used_buffer: [24]u8 = undefined;
    var free_buffer: [24]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buffer, "{s} 已用 · {s} 可用", .{ formatCapacity(used, &used_buffer), formatCapacity(disk.free, &free_buffer) }) catch "";
    text(@src(), detail, C.muted, .{ .id_extra = 66, .padding = .{}, .margin = .{ .y = 2 }, .font = bodyFont().withSize(fs(12)) });
}

fn formatCapacity(bytes: u64, buffer: []u8) []const u8 {
    const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    if (gb >= 10.0) return std.fmt.bufPrint(buffer, "{d:.0} GB", .{gb}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.1} GB", .{gb}) catch "";
}

fn placeLabel(kind: browser.PlaceKind) []const u8 {
    return switch (kind) {
        .home => "主目录",
        .desktop => "桌面",
        .documents => "文档",
        .downloads => "下载",
        .pictures => "图片",
        .music => "音乐",
        .videos => "视频",
        .trash => "回收站",
    };
}

fn placeIcon(kind: browser.PlaceKind) []const u8 {
    return switch (kind) {
        .home => dvui.entypo.home,
        .desktop => dvui.entypo.classic_computer,
        .documents => dvui.entypo.text_document,
        .downloads => dvui.entypo.download,
        .pictures => dvui.entypo.image,
        .music => dvui.entypo.music,
        .videos => dvui.entypo.video,
        .trash => dvui.entypo.trash,
    };
}

fn placeRow(place: *browser.Place, label: []const u8, icon: []const u8, selected: bool, id: usize) bool {
    _ = place;
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{}, .{
        .id_extra = id,
        .label = .{ .text = label },
        .tab_index = 0,
        .expand = .horizontal,
        .min_size_content = .{ .h = 36 },
        .padding = .{ .x = 10, .w = 10 },
        .margin = .{ .h = 1 },
        .border = .{},
        .corners = .all(radii.control),
        .background = true,
        .color_fill = .{ .color = if (selected) C.selected else C.surface },
        .color_fill_hover = .{ .color = if (selected) C.selected else C.raised },
        .color_fill_press = .{ .color = C.raised },
        .role = .none,
    });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .role = .none });
        defer row.deinit();
        dvui.icon(@src(), label, icon, .{}, .{ .id_extra = id, .min_size_content = .all(17), .max_size_content = .all(17), .gravity_y = 0.5, .padding = .{}, .margin = .{ .w = 10 }, .color_text = .{ .color = if (selected) C.accent else C.muted }, .role = .none });
        text(@src(), label, if (selected) C.accent else C.muted, .{ .id_extra = id, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(15)).withWeight(if (selected) .bold else .normal) });
    }
    return button.clicked();
}

// ---------------------------------------------------------------- toolbar

fn renderContent(state: *browser.State, frame: Frame, action: *?Action) void {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 2,
        .expand = .both,
        .padding = .all(content_padding),
        .margin = .{},
        .background = true,
        .color_fill = .{ .color = C.surface },
        .corners = .all(radii.surface),
        .role = .none,
    });
    defer card.deinit();
    renderToolbar(state, frame, action);
    dividerRow(@src(), 90);
    renderStats(state, frame, action);
    const window_rect = dvui.currentWindow().data().rect;
    const available = window_rect.h - window_padding * 2 - content_padding * 2 - toolbar_height - stats_height - status_height - content_gap * 4 - 20;
    renderListing(state, frame, action, @max(120.0, available));
    renderStatus(state, frame);
}

fn renderToolbar(state: *browser.State, frame: Frame, action: *?Action) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = 20,
        .expand = .horizontal,
        .min_size_content = .{ .h = toolbar_height },
        .padding = .{},
        .margin = .{ .h = content_gap / 2 },
        .role = .none,
    });
    defer bar.deinit();

    if (navButton(21, dvui.entypo.arrow_left, state.history.index > 0 and state.mode == .browse)) action.* = .back;
    if (navButton(22, dvui.entypo.arrow_right, state.history.index + 1 < state.history.count and state.mode == .browse)) action.* = .forward;
    if (navButton(23, dvui.entypo.arrow_up, state.mode == .browse and !std.mem.eql(u8, state.path.slice(), "/"))) action.* = .up;
    renderBreadcrumb(state, action);

    var controls = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 27, .gravity_x = 1.0, .padding = .{}, .margin = .{}, .role = .none });
    defer controls.deinit();
    if (search_open) {
        renderSearch(state, frame);
    } else if (navButton(24, dvui.entypo.magnifying_glass, true)) {
        search_open = true;
    }
    renderViewToggle(state, 28);
    if (navButton(29, dvui.entypo.dots_three_horizontal, true)) {
        const mouse = dvui.currentWindow().mouse_pt.toNatural();
        state.menu_at = .{ mouse.x, mouse.y };
        state.menu_mode = .sort;
    }
    if (state.mode == .browse) {
        if (primaryButton(26, "新建文件夹")) {
            state.startDialog(.new_folder, 0, "");
        }
    }
}

fn primaryButton(id: usize, label: []const u8) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{}, .{
        .id_extra = id,
        .label = .{ .text = label },
        .tab_index = 0,
        .min_size_content = .{ .h = 36 },
        .padding = .{ .x = 14, .w = 14 },
        .margin = .{},
        .border = .{},
        .corners = .all(radii.control),
        .background = true,
        .color_fill = .{ .color = C.accent },
        .color_fill_hover = .{ .color = C.accent.lerp(C.text, 0.08) },
        .color_fill_press = .{ .color = C.accent },
        .role = .none,
    });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    {
        var content = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .role = .none });
        defer content.deinit();
        dvui.icon(@src(), label, dvui.entypo.plus, .{}, .{ .id_extra = id, .min_size_content = .all(16), .max_size_content = .all(16), .gravity_y = 0.5, .padding = .{}, .margin = .{ .w = 8 }, .color_text = .{ .color = C.input }, .role = .none });
        text(@src(), label, C.input, .{ .id_extra = id, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(14)).withWeight(.bold) });
    }
    return button.clicked();
}
fn navButton(id: usize, icon: []const u8, enabled: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{}, .{
        .id_extra = id,
        .label = .{ .text = "" },
        .tab_index = 0,
        .min_size_content = .{ .w = nav_size, .h = nav_size },
        .max_size_content = .all(nav_size),
        .padding = .{},
        .margin = .{ .w = 4 },
        .border = .{},
        .corners = .all(radii.control),
        .background = true,
        .color_fill = .{ .color = C.raised },
        .color_fill_hover = .{ .color = C.raised },
        .color_fill_press = .{ .color = C.border },
        .role = .none,
    });
    defer button.deinit();
    if (enabled) button.processEvents();
    button.drawBackground();
    dvui.icon(@src(), icon, icon, .{}, .{ .id_extra = id, .min_size_content = .all(16), .max_size_content = .all(16), .gravity_x = 0.5, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .color_text = .{ .color = if (enabled) C.muted else C.muted }, .role = .none });
    return enabled and button.clicked();
}

fn renderBreadcrumb(state: *browser.State, action: *?Action) void {
    var crumb = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 30, .max_size_content = .width(560), .padding = .{}, .margin = .{ .x = 8, .w = 8 }, .role = .none });
    defer crumb.deinit();
    if (state.mode == .trash) {
        text(@src(), "回收站", C.text, .{ .id_extra = 31, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(15)) });
        return;
    }
    const path = state.path.slice();
    if (path.len == 0) return;
    var ordinal: usize = 0;
    if (path[0] == '/') {
        if (crumbButton(32, "/", std.mem.eql(u8, path, "/"))) {
            if (Files.Text.init("/")) |text_value| {
                action.* = .{ .navigate = text_value };
            } else |_| {}
        }
        ordinal += 1;
    }
    var at: usize = 0;
    while (at < path.len) {
        while (at < path.len and path[at] == '/') at += 1;
        if (at >= path.len) break;
        const start = at;
        while (at < path.len and path[at] != '/') at += 1;
        const segment = path[start..at];
        if (ordinal > 0) {
            dvui.icon(@src(), "›", dvui.entypo.chevron_right, .{}, .{ .id_extra = 33 + ordinal * 4, .min_size_content = .all(14), .max_size_content = .all(14), .gravity_y = 0.5, .padding = .{}, .margin = .{ .x = 4, .w = 4 }, .color_text = .{ .color = C.muted }, .role = .none });
        }
        if (crumbButton(34 + ordinal * 4, segment, at == path.len)) {
            if (Files.Text.init(path[0..at])) |text_value| {
                action.* = .{ .navigate = text_value };
            } else |_| {}
        }
        ordinal += 1;
    }
}

fn crumbButton(id: usize, label: []const u8, current: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{}, .{
        .id_extra = id,
        .label = .{ .text = label },
        .tab_index = 0,
        .min_size_content = .{ .h = 32 },
        .max_size_content = .height(32),
        .padding = .{ .x = 6, .w = 6 },
        .margin = .{},
        .border = .{},
        .corners = .all(radii.control),
        .background = false,
        .color_fill_hover = .{ .color = C.raised },
        .role = .none,
    });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    text(@src(), label, if (current) C.text else C.muted, .{ .id_extra = id, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(15)) });
    return button.clicked();
}

fn renderViewToggle(state: *browser.State, id: usize) void {
    var group = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .min_size_content = .{ .w = 72, .h = 32 }, .max_size_content = .{ .w = 72, .h = 32 }, .padding = .all(2), .margin = .{ .w = 4 }, .background = true, .color_fill = .{ .color = C.input }, .corners = .all(radii.control), .role = .none });
    defer group.deinit();
    if (segmentButton(id + 1, dvui.entypo.grid, state.view == .grid)) state.view = .grid;
    if (segmentButton(id + 2, dvui.entypo.list, state.view == .list)) state.view = .list;
}

fn segmentButton(id: usize, icon: []const u8, selected: bool) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{}, .{
        .id_extra = id,
        .label = .{ .text = "" },
        .tab_index = 0,
        .min_size_content = .{ .w = 32, .h = 28 },
        .max_size_content = .{ .w = 32, .h = 28 },
        .padding = .{},
        .margin = .{},
        .border = .{},
        .corners = .all(6),
        .background = selected,
        .color_fill = .{ .color = C.raised },
        .color_fill_hover = .{ .color = C.raised },
        .color_fill_press = .{ .color = C.border },
        .role = .none,
    });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    dvui.icon(@src(), icon, icon, .{}, .{ .id_extra = id, .min_size_content = .all(16), .max_size_content = .all(16), .gravity_x = 0.5, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .color_text = .{ .color = if (selected) C.text else C.muted }, .role = .none });
    return button.clicked();
}

fn renderSearch(state: *browser.State, frame: Frame) void {
    var field = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 40, .min_size_content = .{ .w = 280, .h = 36 }, .max_size_content = .{ .w = 280, .h = 36 }, .padding = .{ .x = 10, .w = 10 }, .margin = .{ .w = 4 }, .background = true, .color_fill = .{ .color = C.input }, .corners = .all(radii.control), .role = .none });
    defer field.deinit();
    dvui.icon(@src(), "搜索", dvui.entypo.magnifying_glass, .{}, .{ .id_extra = 41, .min_size_content = .all(16), .max_size_content = .all(16), .gravity_y = 0.5, .padding = .{}, .margin = .{ .w = 6 }, .color_text = .{ .color = C.muted }, .role = .none });
    const entry = dvui.textEntry(@src(), .{
        .text = .{ .array_list = .{ .backing = &state.query, .allocator = frame.allocator } },
        .placeholder = "搜索当前文件夹",
    }, .{
        .id_extra = 42,
        .expand = .horizontal,
        .min_size_content = .{ .h = 28 },
        .font = bodyFont().withSize(fs(14)),
        .padding = .{ .x = 4, .w = 4 },
        .margin = .{},
        .border = .{},
        .background = false,
        .label = .{ .text = "搜索" },
    });
    search_focus_id = entry.data().id;
    defer entry.deinit();
    state.reconcileVisibility();
}

fn renderStats(state: *browser.State, frame: Frame, action: *?Action) void {
    _ = frame;
    _ = action;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 70, .expand = .horizontal, .min_size_content = .{ .h = stats_height }, .padding = .{}, .margin = .{ .h = content_gap / 2 }, .role = .none });
    defer row.deinit();
    var buffer: [128]u8 = undefined;
    const label = if (state.querySlice().len != 0)
        std.fmt.bufPrint(&buffer, "{d} 个结果 · 搜索“{s}”", .{ state.visibleCount(), state.querySlice() }) catch ""
    else
        std.fmt.bufPrint(&buffer, "{d} 个项目", .{state.visibleCount()}) catch "";
    text(@src(), label, C.muted, .{ .id_extra = 71, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(13)) });
    if (sortTrigger(state, 72)) {
        const mouse = dvui.currentWindow().mouse_pt.toNatural();
        state.menu_at = .{ mouse.x, mouse.y };
        state.menu_mode = .sort;
    }
}

fn sortLabel(sort: Files.Sort) []const u8 {
    return switch (sort) {
        .name => "名称",
        .size => "大小",
        .modified => "修改时间",
        .type => "类型",
    };
}

fn sortTrigger(state: *browser.State, id: usize) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{}, .{
        .id_extra = id,
        .label = .{ .text = "排序" },
        .tab_index = 0,
        .min_size_content = .{ .h = 24 },
        .padding = .{ .x = 8, .w = 8 },
        .margin = .{},
        .border = .{},
        .corners = .all(radii.control),
        .background = false,
        .color_fill_hover = .{ .color = C.raised },
        .gravity_x = 1.0,
        .role = .none,
    });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id, .expand = .horizontal, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .role = .none });
        defer row.deinit();
        text(@src(), sortLabel(state.sort), C.muted, .{ .id_extra = id, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(13)) });
        dvui.icon(@src(), "chevron", dvui.entypo.chevron_down, .{}, .{ .id_extra = id, .min_size_content = .all(14), .max_size_content = .all(14), .gravity_y = 0.5, .padding = .{}, .margin = .{ .x = 4 }, .color_text = .{ .color = C.muted }, .role = .none });
    }
    return button.clicked();
}

// ---------------------------------------------------------------- listing

fn renderListing(state: *browser.State, frame: Frame, action: *?Action, height: f32) void {
    var scroll = dvui.scrollArea(@src(), .{ .vertical = .auto, .horizontal = .none, .focus_id = null }, .{
        .id_extra = 300,
        .expand = .horizontal,
        .min_size_content = .{ .h = height },
        .max_size_content = .height(height),
        .padding = .{ .x = 2, .y = 2, .w = 2, .h = 2 },
        .margin = .{ .h = content_gap / 2 },
        .role = .none,
    });
    defer scroll.deinit();
    const width = scroll.data().contentRect().w;
    if (state.loading and state.items.items.len == 0) {
        text(@src(), "载入中…", C.muted, .{ .id_extra = 301, .gravity_x = 0.5, .padding = .{}, .margin = .{ .y = 24 }, .font = bodyFont().withSize(fs(14)) });
        return;
    }
    if (state.visibleCount() == 0) {
        renderEmpty(state, frame, action);
        return;
    }
    switch (state.view) {
        .grid => renderGrid(state, frame, action, width),
        .list => renderList(state, frame, action, width),
    }
}

fn renderGrid(state: *browser.State, frame: Frame, action: *?Action, width: f32) void {
    const columns = @max(1, @as(usize, @intFromFloat(@floor((width + tile_gap) / (tile_width + tile_gap)))));
    var row: ?*dvui.BoxWidget = null;
    var column: usize = 0;
    for (state.items.items, 0..) |*item, index| {
        if (!state.visible(item)) continue;
        if (row == null or column == columns) {
            if (row) |current| current.deinit();
            row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 200 + index, .expand = .horizontal, .padding = .{}, .margin = .{}, .role = .none });
            column = 0;
        }
        renderTile(state, frame, action, item, index);
        column += 1;
    }
    if (row) |current| current.deinit();
}

fn renderTile(state: *browser.State, frame: Frame, action: *?Action, item: *const browser.Item, index: usize) void {
    const selected = state.selected == index;
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{}, .{
        .id_extra = 20000 + index,
        .label = .{ .text = item.name() },
        .tab_index = 0,
        .min_size_content = .{ .w = tile_width, .h = tile_height },
        .max_size_content = .{ .w = tile_width, .h = tile_height },
        .padding = .{},
        .margin = .{ .x = tile_gap / 2, .h = tile_gap / 2 },
        .border = .{},
        .corners = .all(radii.control),
        .background = true,
        .color_fill = .{ .color = if (selected) C.selected else C.surface },
        .color_fill_hover = .{ .color = if (selected) C.selected else C.raised },
        .color_fill_press = .{ .color = C.raised },
        .role = .none,
    });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    {
        var content = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = 20000 + index, .gravity_x = 0.5, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .role = .none });
        defer content.deinit();
        fileIcon(frame, item, 48, 20000 + index, true);
        textAligned(@src(), item.name(), C.text, 0.5, .{
            .id_extra = 20000 + index,
            .padding = .{ .x = 6, .w = 6 },
            .margin = .{ .y = 6 },
            .max_size_content = .width(tile_width - 12),
            .font = bodyFont().withSize(fs(13)),
        });
    }
    button.drawFocus();
    itemEvents(state, frame, action, &button, index);
}

fn renderList(state: *browser.State, frame: Frame, action: *?Action, width: f32) void {
    const name_width = @max(160.0, width - 18 - cell_gap * 4 - size_width - time_width - kind_width - 32);
    var header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 11000, .expand = .horizontal, .min_size_content = .{ .h = 32 }, .padding = .{ .x = 12, .w = 12 }, .margin = .{}, .role = .none });
    {
        var spacer = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 11009, .min_size_content = .{ .w = 18 }, .max_size_content = .width(18), .padding = .{}, .margin = .{}, .role = .none });
        spacer.deinit();
    }
    text(@src(), "名称", C.muted, .{ .id_extra = 11001, .min_size_content = .{ .w = name_width }, .padding = .{}, .margin = .{ .x = cell_gap }, .font = bodyFont().withSize(fs(13)).withWeight(.bold) });
    textAligned(@src(), "大小", C.muted, 1.0, .{ .id_extra = 11002, .min_size_content = .{ .w = size_width }, .padding = .{}, .margin = .{ .x = cell_gap }, .font = bodyFont().withSize(fs(13)).withWeight(.bold) });
    text(@src(), "修改时间", C.muted, .{ .id_extra = 11003, .min_size_content = .{ .w = time_width }, .padding = .{}, .margin = .{ .x = cell_gap }, .font = bodyFont().withSize(fs(13)).withWeight(.bold) });
    text(@src(), "类型", C.muted, .{ .id_extra = 11004, .min_size_content = .{ .w = kind_width }, .padding = .{}, .margin = .{ .x = cell_gap }, .font = bodyFont().withSize(fs(13)).withWeight(.bold) });
    header.deinit();
    for (state.items.items, 0..) |*item, index| {
        if (!state.visible(item)) continue;
        renderRow(state, frame, action, item, index, name_width);
    }
}

fn renderRow(state: *browser.State, frame: Frame, action: *?Action, item: *const browser.Item, index: usize, name_width: f32) void {
    const selected = state.selected == index;
    var button: dvui.ButtonWidget = undefined;
    button.init(@src(), .{}, .{
        .id_extra = 30000 + index,
        .label = .{ .text = item.name() },
        .tab_index = 0,
        .expand = .horizontal,
        .min_size_content = .{ .h = 40 },
        .padding = .{ .x = 12, .w = 12 },
        .margin = .{ .h = 1 },
        .border = .{},
        .corners = .all(radii.control),
        .background = true,
        .color_fill = .{ .color = if (selected) C.selected else C.surface },
        .color_fill_hover = .{ .color = if (selected) C.selected else C.raised },
        .color_fill_press = .{ .color = C.raised },
        .role = .none,
    });
    defer button.deinit();
    button.processEvents();
    button.drawBackground();
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 30000 + index, .expand = .horizontal, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .role = .none });
        defer row.deinit();
        fileIcon(frame, item, 18, 30000 + index, false);
        text(@src(), item.name(), C.text, .{ .id_extra = 30000 + index, .min_size_content = .{ .w = name_width }, .max_size_content = .width(name_width), .padding = .{}, .margin = .{ .x = cell_gap }, .font = bodyFont().withSize(fs(14)).withWeight(if (selected) .bold else .normal) });
        var size_buffer: [32]u8 = undefined;
        textAligned(@src(), if (item.kind == .directory) "—" else formatSize(item.size, &size_buffer), C.muted, 1.0, .{ .id_extra = 30000 + index, .min_size_content = .{ .w = size_width }, .padding = .{}, .margin = .{ .x = cell_gap }, .font = bodyFont().withSize(fs(13)) });
        var time_buffer: [32]u8 = undefined;
        text(@src(), formatModified(item.modified, &time_buffer), C.muted, .{ .id_extra = 30000 + index, .min_size_content = .{ .w = time_width }, .padding = .{}, .margin = .{ .x = cell_gap }, .font = bodyFont().withSize(fs(13)) });
        text(@src(), browser.State.kindLabel(item.kind), C.muted, .{ .id_extra = 30000 + index, .min_size_content = .{ .w = kind_width }, .padding = .{}, .margin = .{ .x = cell_gap }, .font = bodyFont().withSize(fs(13)) });
    }
    button.drawFocus();
    itemEvents(state, frame, action, &button, index);
}

fn itemEvents(state: *browser.State, frame: Frame, action: *?Action, button: *dvui.ButtonWidget, index: usize) void {
    const wd = button.data();
    for (dvui.events()) |*event| {
        if (!dvui.eventMatchSimple(event, wd)) continue;
        switch (event.evt) {
            .mouse => |mouse| {
                if (mouse.action != .press or mouse.button != .right) continue;
                if (!wd.borderRectScale().r.contains(mouse.p)) continue;
                const natural = mouse.p.toNatural();
                state.menu_mode = .context;
                state.menu_at = .{ natural.x, natural.y };
                state.menu_index = index;
                state.select(index);
                event.handled = true;
            },
            else => {},
        }
    }
    if (!button.clicked()) return;
    const now = frame.now_ms;
    const double_click = state.last_click_index == index and now >= state.last_click_ms and now - state.last_click_ms < 400;
    state.select(index);
    state.last_click_ms = now;
    state.last_click_index = index;
    if (double_click) {
        action.* = .{ .open = index };
    } else if (state.menu_mode != .none) {
        state.menu_mode = .none;
    }
}

pub fn iconKey(item: *const browser.Item, logical: u32, scale: u32) icons.Key {
    return .{
        // File-operation text already satisfies the same bounded UTF-8 contract.
        .path = icons.Text.init(item.path.slice()) catch unreachable,
        .desktop_icon = icons.Text.init(item.icon.slice()) catch unreachable,
        .desktop_launcher = item.launcher,
        .kind = item.kind,
        .modified = item.modified,
        .size = item.size,
        .logical_size = logical,
        .scale = scale,
    };
}

/// Pixel size the theme icon is decoded at for the current view.
pub fn iconLogical(view: browser.View) u32 {
    return switch (view) {
        .grid => 48,
        .list => 18,
    };
}

fn fileIcon(frame: Frame, item: *const browser.Item, logical: u32, id: usize, center: bool) void {
    const key = iconKey(item, logical, frame.scale);
    const found = frame.icons.get(key);
    if (found) |image| {
        var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = id,
            .min_size_content = .{ .w = @floatFromInt(logical), .h = @floatFromInt(logical) },
            .max_size_content = .{ .w = @floatFromInt(logical), .h = @floatFromInt(logical) },
            .gravity_x = if (center) 0.5 else 0,
            .padding = .{},
            .margin = .{},
            .role = .none,
        });
        defer slot.deinit();
        dvui.renderImage(.{ .pixels = .{ .rgba = image.rgba, .width = image.width, .height = image.height, .invalidation = .bytes } }, slot.data().contentRectScale(), .{}) catch {};
    } else if (frame.icons.awaiting(key)) {
        // Decode still in flight: hold the footprint with a quiet skeleton so the
        // tile never flips from a built-in glyph to the theme icon.
        var slot = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = id,
            .min_size_content = .{ .w = @floatFromInt(logical), .h = @floatFromInt(logical) },
            .max_size_content = .{ .w = @floatFromInt(logical), .h = @floatFromInt(logical) },
            .gravity_x = if (center) 0.5 else 0,
            .padding = .{},
            .margin = .{},
            .background = true,
            .color_fill = .{ .color = C.track },
            .corners = .all(10),
            .role = .none,
        });
        slot.deinit();
    } else {
        dvui.icon(@src(), item.name(), fallbackIcon(item.kind), .{}, .{
            .id_extra = id,
            .min_size_content = .all(20),
            .max_size_content = .all(20),
            .gravity_x = if (center) 0.5 else 0,
            .padding = .{},
            .margin = .{},
            .color_text = .{ .color = if (item.kind == .directory) C.accent else C.muted },
            .role = .none,
        });
    }
}

fn fallbackIcon(kind: std.Io.File.Kind) []const u8 {
    return switch (kind) {
        .directory => dvui.entypo.folder,
        else => dvui.entypo.text_document,
    };
}

fn renderEmpty(state: *browser.State, frame: Frame, action: *?Action) void {
    _ = frame;
    _ = action;
    var area = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = 700, .expand = .both, .padding = .{}, .margin = .{}, .role = .none });
    defer area.deinit();
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = 701, .gravity_x = 0.5, .gravity_y = 0.5, .padding = .all(24), .margin = .{}, .role = .none });
    defer panel.deinit();
    dvui.icon(@src(), "空文件夹", dvui.entypo.folder, .{}, .{ .id_extra = 702, .min_size_content = .all(40), .max_size_content = .all(40), .gravity_x = 0.5, .padding = .{}, .margin = .{ .h = 10 }, .color_text = .{ .color = C.muted }, .role = .none });
    text(@src(), if (state.querySlice().len != 0) "没有匹配的项目" else "这个文件夹是空的", C.muted, .{ .id_extra = 703, .gravity_x = 0.5, .padding = .{}, .margin = .{ .h = 10 }, .font = bodyFont().withSize(fs(14)) });
    if (state.querySlice().len != 0) {
        if (Components.button(@src(), "清除搜索", .{}, .{ .id_extra = 704, .min_size_content = .{ .h = 32 } })) state.setQuery("");
    } else if (state.mode == .browse) {
        if (Components.button(@src(), "新建文件夹", .{ .icon = dvui.entypo.plus, .tone = .primary }, .{ .id_extra = 705, .min_size_content = .{ .h = 32 } })) state.startDialog(.new_folder, 0, "");
    }
}

// ---------------------------------------------------------------- status

fn renderStatus(state: *browser.State, frame: Frame) void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = 600,
        .expand = .horizontal,
        .min_size_content = .{ .h = status_height },
        .padding = .{},
        .margin = .{ .h = content_gap / 2 },
        .role = .none,
    });
    defer bar.deinit();
    var folders: usize = 0;
    var files: usize = 0;
    for (state.items.items) |*item| {
        if (!state.visible(item)) continue;
        if (item.kind == .directory) folders += 1 else files += 1;
    }
    var message_buffer: [160]u8 = undefined;
    const toast = state.toastText(frame.now_ms);
    const message = if (toast.len != 0)
        toast
    else if (state.loading)
        "载入中…"
    else
        std.fmt.bufPrint(&message_buffer, "{d} 个文件夹 · {d} 个文件", .{ folders, files }) catch "";
    text(@src(), message, if (toast.len != 0) C.accent else C.muted, .{ .id_extra = 601, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(12)) });
    if (state.selectedItem()) |item| {
        var detail_buffer: [160]u8 = undefined;
        var size_buffer: [32]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buffer, "· 已选 {s}（{s}）", .{
            item.name(),
            if (item.kind == .directory) "文件夹" else formatSize(item.size, &size_buffer),
        }) catch "";
        text(@src(), detail, C.muted, .{ .id_extra = 604, .gravity_y = 0.5, .padding = .{}, .margin = .{ .x = 8 }, .max_size_content = .width(420), .font = bodyFont().withSize(fs(12)) });
    }
    if (state.skipped != 0) {
        var skipped_buffer: [80]u8 = undefined;
        const skipped = std.fmt.bufPrint(&skipped_buffer, "已跳过 {d} 个无法显示的项目", .{state.skipped}) catch "已跳过无法显示的项目";
        text(@src(), skipped, C.warning, .{ .id_extra = 605, .gravity_y = 0.5, .padding = .{}, .margin = .{ .x = 12 }, .font = bodyFont().withSize(fs(12)) });
    }
    if (state.truncated) {
        text(@src(), "已截断（最多 1024 项）", C.warning, .{ .id_extra = 602, .gravity_y = 0.5, .padding = .{}, .margin = .{ .x = 12 }, .font = bodyFont().withSize(fs(12)) });
    }
    if (frame.font_message) |note| {
        text(@src(), note, C.warning, .{ .id_extra = 603, .gravity_y = 0.5, .padding = .{}, .margin = .{ .x = 12 }, .font = bodyFont().withSize(fs(12)) });
    }
    if (frame.disk) |disk| {
        var free_buffer: [24]u8 = undefined;
        var capacity_buffer: [48]u8 = undefined;
        const capacity = std.fmt.bufPrint(&capacity_buffer, "可用 {s}", .{formatCapacity(disk.free, &free_buffer)}) catch "";
        text(@src(), capacity, C.muted, .{ .id_extra = 605, .gravity_x = 1.0, .gravity_y = 0.5, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(12)) });
    }
}

// ---------------------------------------------------------------- menu

fn renderMenu(state: *browser.State, frame: Frame, action: *?Action) void {
    if (state.menu_mode == .none) return;
    var open = true;
    const popup = dvui.popup(@src(), .{ .open_flag = &open, .from = .{ .x = state.menu_at[0], .y = state.menu_at[1] } }, Components.menuSurfaceOptions(.{ .id_extra = 400, .min_size_content = .{ .w = 232 } })) orelse {
        state.menu_mode = .none;
        return;
    };
    defer if (!open) {
        state.menu_mode = .none;
    };
    defer popup.deinit();
    if (state.menu_mode == .sort) {
        sortMenu(state, action);
    } else {
        contextMenu(state, frame, action);
    }
}

fn sortMenu(state: *browser.State, action: *?Action) void {
    const entries = [_]struct { label: []const u8, sort: Files.Sort }{
        .{ .label = "名称", .sort = .name },
        .{ .label = "大小", .sort = .size },
        .{ .label = "修改时间", .sort = .modified },
        .{ .label = "类型", .sort = .type },
    };
    for (entries, 0..) |entry, index| {
        if (Components.menuRow(@src(), entry.label, .{ .icon = if (state.sort == entry.sort) dvui.entypo.check else null }, .{ .id_extra = 410 + index })) {
            action.* = .{ .set_sort = entry.sort };
        }
    }
    _ = Components.menuRow(@src(), "", .{}, .{ .id_extra = 415, .min_size_content = .{ .h = 1 }, .padding = .{}, .background = true, .color_fill = .{ .color = C.border } });
    if (Components.menuRow(@src(), "显示隐藏文件", .{ .icon = if (state.show_hidden) dvui.entypo.check else null }, .{ .id_extra = 416 })) action.* = .toggle_hidden;
    if (Components.menuRow(@src(), "刷新", .{ .icon = dvui.entypo.cycle }, .{ .id_extra = 417 })) action.* = .refresh;
}

fn contextMenu(state: *browser.State, frame: Frame, action: *?Action) void {
    const index = state.menu_index;
    if (index >= state.items.items.len) return;
    const item = state.items.items[index];
    if (state.mode == .trash) {
        if (Components.menuRow(@src(), "还原", .{ .icon = dvui.entypo.arrow_left }, .{ .id_extra = 430 })) action.* = .{ .restore = index };
        if (Components.menuRow(@src(), "彻底删除", .{ .icon = dvui.entypo.trash }, .{ .id_extra = 431 })) state.startDialog(.confirm_delete, index, item.name());
        if (Components.menuRow(@src(), "清空回收站", .{ .icon = dvui.entypo.trash }, .{ .id_extra = 432 })) state.startDialog(.confirm_empty, index, "");
        return;
    }
    if (Components.menuRow(@src(), "打开", .{ .icon = dvui.entypo.folder }, .{ .id_extra = 433 })) action.* = .{ .open = index };
    if (Components.menuRow(@src(), "复制", .{ .icon = dvui.entypo.clipboard }, .{ .id_extra = 434 })) action.* = .{ .copy = index };
    if (Components.menuRow(@src(), "剪切", .{ .icon = dvui.entypo.scissors }, .{ .id_extra = 435 })) action.* = .{ .cut = index };
    if (state.clipboard != null) {
        if (Components.menuRow(@src(), "粘贴到此处", .{ .icon = dvui.entypo.clipboard }, .{ .id_extra = 436 })) action.* = .paste;
    }
    if (Components.menuRow(@src(), "重命名", .{ .icon = dvui.entypo.pencil }, .{ .id_extra = 437 })) state.startDialog(.rename, index, item.name());
    if (Components.menuRow(@src(), "移到回收站", .{ .icon = dvui.entypo.trash }, .{ .id_extra = 438 })) state.startDialog(.confirm_trash, index, item.name());
    if (Components.menuRow(@src(), "属性", .{ .icon = dvui.entypo.info }, .{ .id_extra = 439 })) action.* = .{ .properties = index };
    _ = frame;
}

// ---------------------------------------------------------------- dialog

fn renderDialog(state: *browser.State, frame: Frame, action: *?Action) void {
    if (state.dialog.kind == .none) return;
    const window_rect = dvui.currentWindow().data().rect;
    var open = true;
    var overlay = dvui.floatingWindow(@src(), .{ .modal = true, .modal_alpha = 184, .resize = .none, .window_avoid = .none, .open_flag = &open }, .{ .id_extra = 500, .rect = window_rect, .background = false, .color_text = .{ .color = C.background }, .padding = .{}, .margin = .{}, .border = .{}, .role = .dialog });
    defer {
        overlay.deinit();
        if (!open) state.closeDialog();
    }
    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 501,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 440 },
        .max_size_content = .width(520),
        .padding = .all(24),
        .margin = .{},
        .background = true,
        .color_fill = .{ .color = C.surface },
        .border = .all(1),
        .color_border = .{ .color = C.border },
        .corners = .all(radii.popup),
        .role = .none,
    });
    defer panel.deinit();
    switch (state.dialog.kind) {
        .new_folder, .rename => inputDialog(state, frame, action),
        .confirm_trash => confirmDialog(state, action, "移到回收站？", "可以稍后从回收站还原。", "移到回收站", .trash),
        .confirm_delete => confirmDialog(state, action, "彻底删除？", "此操作无法撤销。", "彻底删除", .delete_permanently),
        .confirm_empty => confirmDialog(state, action, "清空回收站？", "回收站中的所有项目都会被删除。", "清空", .empty_trash),
        .properties => propertiesDialog(state),
        .none => {},
    }
}

fn inputDialog(state: *browser.State, frame: Frame, action: *?Action) void {
    const is_folder = state.dialog.kind == .new_folder;
    const title = if (is_folder) "新建文件夹" else "重命名";
    text(@src(), title, C.text, .{ .id_extra = 510, .padding = .{}, .margin = .{ .h = 12 }, .font = bodyFont().withSize(fs(18)).withWeight(.bold) });
    const entry = dvui.textEntry(@src(), .{
        .text = .{ .array_list = .{ .backing = &state.dialog.text, .allocator = frame.allocator } },
    }, .{
        .id_extra = 511,
        .expand = .horizontal,
        .min_size_content = .{ .h = 34 },
        .font = bodyFont(),
        .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
        .border = .all(1),
        .color_border = .{ .color = C.accent },
        .corners = .all(radii.control),
        .background = true,
        .color_fill = .{ .color = C.input },
        .label = .{ .text = title },
    });
    if (entry.enter_pressed) {
        confirmInput(state, action, is_folder, frame.now_ms);
    }
    entry.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 512, .gravity_x = 1.0, .padding = .{}, .margin = .{ .y = 14 }, .role = .none });
    defer row.deinit();
    if (Components.button(@src(), "取消", .{}, .{ .id_extra = 513, .min_size_content = .{ .h = 34 }, .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 }, .margin = .{} })) {
        state.closeDialog();
        return;
    }
    if (Components.button(@src(), if (is_folder) "创建" else "保存", .{ .tone = .primary }, .{ .id_extra = 514, .min_size_content = .{ .h = 34 }, .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 }, .margin = .{ .x = 8 } })) {
        confirmInput(state, action, is_folder, frame.now_ms);
    }
}

fn confirmInput(state: *browser.State, action: *?Action, _: bool, now: u64) void {
    const bytes = state.dialog.text.items;
    if (bytes.len == 0) {
        state.notify(now, "名称不能为空");
        return;
    }
    const name = Files.Text.init(bytes) catch {
        state.notify(now, "名称过长");
        return;
    };
    if (state.confirmDialog(name)) |request| action.* = .{ .confirmed = request };
}

fn confirmDialog(state: *browser.State, action: *?Action, title: []const u8, body: []const u8, confirm_label: []const u8, _: enum { trash, delete_permanently, empty_trash }) void {
    text(@src(), title, C.text, .{ .id_extra = 520, .padding = .{}, .margin = .{ .h = 8 }, .font = bodyFont().withSize(fs(18)).withWeight(.bold) });
    if (state.dialog.text.items.len != 0) text(@src(), state.dialog.text.items, C.text, .{ .id_extra = 525, .padding = .{}, .margin = .{ .h = 8 }, .expand = .horizontal, .font = bodyFont().withSize(fs(13)) });
    text(@src(), body, C.muted, .{ .id_extra = 521, .padding = .{}, .margin = .{ .h = 16 }, .font = bodyFont().withSize(fs(13)) });
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 522, .gravity_x = 1.0, .padding = .{}, .margin = .{}, .role = .none });
    defer row.deinit();
    if (Components.button(@src(), confirm_label, .{ .tone = .danger }, .{ .id_extra = 524, .gravity_x = 1.0, .min_size_content = .{ .h = 34 }, .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 }, .margin = .{ .x = 8 } })) {
        if (state.confirmDialog(.{})) |request| action.* = .{ .confirmed = request };
    }
    if (Components.button(@src(), "取消", .{}, .{ .id_extra = 523, .gravity_x = 1.0, .min_size_content = .{ .h = 34 }, .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 }, .margin = .{} })) {
        state.closeDialog();
    }
}

fn propertiesDialog(state: *browser.State) void {
    const properties = state.dialog.properties;
    text(@src(), "属性", C.text, .{ .id_extra = 530, .padding = .{}, .margin = .{ .h = 12 }, .font = bodyFont().withSize(fs(18)).withWeight(.bold) });
    const rows = [_]struct { label: []const u8, value: []const u8 }{
        .{ .label = "名称", .value = properties.name.slice() },
        .{ .label = "路径", .value = properties.path.slice() },
        .{ .label = "类型", .value = browser.State.kindLabel(properties.kind) },
    };
    for (rows, 0..) |row, index| {
        {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 531 + index, .expand = .horizontal, .padding = .{}, .margin = .{ .h = 4 }, .role = .none });
            defer line.deinit();
            text(@src(), row.label, C.muted, .{ .id_extra = 540 + index, .min_size_content = .{ .w = 64 }, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(13)) });
            text(@src(), row.value, C.text, .{ .id_extra = 550 + index, .expand = .horizontal, .padding = .{}, .margin = .{}, .max_size_content = .width(320), .font = bodyFont().withSize(fs(13)) });
        }
    }
    var size_buffer: [32]u8 = undefined;
    var time_buffer: [32]u8 = undefined;
    var links_buffer: [32]u8 = undefined;
    var inode_buffer: [32]u8 = undefined;
    const details = [_]struct { label: []const u8, value: []const u8 }{
        .{ .label = "大小", .value = if (properties.kind == .directory) "—" else formatSize(properties.size, &size_buffer) },
        .{ .label = "修改时间", .value = formatModified(properties.modified, &time_buffer) },
        .{ .label = "链接数", .value = std.fmt.bufPrint(&links_buffer, "{d}", .{properties.links}) catch "" },
        .{ .label = "inode", .value = std.fmt.bufPrint(&inode_buffer, "{d}", .{properties.inode}) catch "" },
    };
    for (details, 0..) |row, index| {
        {
            var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 560 + index, .expand = .horizontal, .padding = .{}, .margin = .{ .h = 4 }, .role = .none });
            defer line.deinit();
            text(@src(), row.label, C.muted, .{ .id_extra = 570 + index, .min_size_content = .{ .w = 64 }, .padding = .{}, .margin = .{}, .font = bodyFont().withSize(fs(13)) });
            text(@src(), row.value, C.text, .{ .id_extra = 580 + index, .expand = .horizontal, .padding = .{}, .margin = .{}, .max_size_content = .width(320), .font = bodyFont().withSize(fs(13)) });
        }
    }
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = 590, .gravity_x = 1.0, .padding = .{}, .margin = .{ .y = 14 }, .role = .none });
    defer row.deinit();
    if (Components.button(@src(), "关闭", .{ .tone = .primary }, .{ .id_extra = 591, .gravity_x = 1.0, .min_size_content = .{ .h = 34 }, .padding = .{ .x = 14, .y = 6, .w = 14, .h = 6 } })) state.closeDialog();
}

// ---------------------------------------------------------------- keyboard

fn keyboard(state: *browser.State, frame: Frame) ?Action {
    if (state.dialog.kind != .none) {
        if (keyDown(.escape)) {
            state.closeDialog();
            return null;
        }
        return null;
    }
    if (dvui.focusedWidgetId()) |focused| {
        if (search_focus_id) |search_id| {
            if (focused == search_id) return null;
        }
    }
    if (keyDown(.escape)) {
        if (search_open) {
            search_open = false;
            state.setQuery("");
            return null;
        }
        if (state.menu_mode != .none) {
            state.menu_mode = .none;
            return null;
        }
        return null;
    }
    if (state.menu_mode != .none) return null;
    const control = ctrlDown();
    const vertical = keyPressCount(.down) - keyPressCount(.up);
    if (vertical != 0) {
        moveSelection(state, vertical);
        return null;
    }
    if (keyDown(.enter)) {
        if (state.selected) |index| return .{ .open = index };
        return null;
    }
    if (keyDown(.backspace)) {
        if (control) return .refresh;
        return .up;
    }
    if (keyDown(.f2) and state.mode == .browse) {
        if (state.selected) |index| {
            if (index < state.items.items.len) state.startDialog(.rename, index, state.items.items[index].name());
        }
        return null;
    }
    if (keyDown(.delete)) {
        if (state.selected) |index| {
            if (state.mode == .trash) {
                state.startDialog(.confirm_delete, index, if (index < state.items.items.len) state.items.items[index].name() else "");
            } else if (index < state.items.items.len) {
                state.startDialog(.confirm_trash, index, state.items.items[index].name());
            }
        }
        return null;
    }
    if (control) {
        if (keyDown(.c)) {
            if (state.selected) |index| if (state.canStash(index)) return .{ .copy = index };
        }
        if (keyDown(.x)) {
            if (state.selected) |index| if (state.canStash(index)) return .{ .cut = index };
        }
        if (keyDown(.v)) return .paste;
        if (keyDown(.h)) return .toggle_hidden;
        if (keyDown(.f)) {
            search_open = true;
            return null;
        }
        if (keyDown(.r)) return .refresh;
        if (keyDown(.n)) {
            if (state.mode == .browse) state.startDialog(.new_folder, 0, "");
            return null;
        }
        if (keyDown(.one)) state.view = .grid;
        if (keyDown(.two)) state.view = .list;
        if (keyDown(.a)) {
            state.selected = state.visibleAt(0);
            return null;
        }
    }
    _ = frame;
    return null;
}

fn keyPressCount(code: dvui.enums.Key) i32 {
    var count: i32 = 0;
    for (dvui.events()) |*event| {
        switch (event.evt) {
            .key => |key| {
                if (key.code != code) continue;
                if (key.action == .up) continue;
                count += 1;
            },
            else => {},
        }
    }
    return count;
}

fn keyDown(code: dvui.enums.Key) bool {
    for (dvui.events()) |*event| {
        switch (event.evt) {
            .key => |key| {
                if (key.code != code) continue;
                if (key.action == .up) continue;
                event.handled = true;
                return true;
            },
            else => {},
        }
    }
    return false;
}

fn ctrlDown() bool {
    for (dvui.events()) |*event| {
        switch (event.evt) {
            .key => |key| return key.mod.control(),
            else => {},
        }
    }
    return false;
}

fn moveSelection(state: *browser.State, direction: i32) void {
    const count = state.visibleCount();
    if (count == 0) return;
    var ordinal: usize = 0;
    if (state.selected) |selected| {
        var seen: usize = 0;
        for (state.items.items, 0..) |*item, index| {
            if (!state.visible(item)) continue;
            if (index == selected) {
                ordinal = seen;
                break;
            }
            seen += 1;
        }
    }
    const delta: isize = direction;
    const target: isize = @as(isize, @intCast(ordinal)) + delta;
    const next: usize = @intCast(std.math.clamp(target, 0, @as(isize, @intCast(count - 1))));
    state.selected = state.visibleAt(next);
}

// ---------------------------------------------------------------- formatting

fn formatSize(size: u64, buffer: []u8) []const u8 {
    if (size < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{size}) catch "";
    const kb = @as(f64, @floatFromInt(size)) / 1024.0;
    if (kb < 1024) return std.fmt.bufPrint(buffer, "{d:.1} KB", .{kb}) catch "";
    const mb = kb / 1024.0;
    if (mb < 1024) return std.fmt.bufPrint(buffer, "{d:.1} MB", .{mb}) catch "";
    const gb = mb / 1024.0;
    return std.fmt.bufPrint(buffer, "{d:.1} GB", .{gb}) catch "";
}

const Civil = struct { year: i64, month: u32, day: u32 };

fn civilFromDays(days_since_epoch: i64) Civil {
    const z = days_since_epoch + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = if (month <= 2) year + 1 else year, .month = @intCast(month), .day = @intCast(day) };
}

fn formatModified(value: i96, buffer: []u8) []const u8 {
    if (value <= 0) return "—";
    const seconds_signed = @divFloor(value, std.time.ns_per_s);
    if (seconds_signed < 0) return "—";
    const seconds: u64 = @intCast(seconds_signed);
    const days: i64 = @intCast(seconds / 86400);
    const seconds_of_day: u64 = seconds % 86400;
    const civil = civilFromDays(days);
    const hour = seconds_of_day / 3600;
    const minute = (seconds_of_day % 3600) / 60;
    const year: u64 = @intCast(civil.year);
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ year, civil.month, civil.day, hour, minute }) catch "";
}
