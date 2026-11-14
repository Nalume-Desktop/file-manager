//! zfiler: an independent Wayland file manager.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try @import("file_manager/app.zig").run(init);
}
