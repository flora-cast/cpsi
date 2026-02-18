const std = @import("std");
const constants = @import("constants");
const utils = @import("utils");

pub fn clean_cache(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const prefix_real_path = try std.fs.realpathAlloc(allocator, prefix);
    defer allocator.free(prefix_real_path);

    const prefixed = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix_real_path, constants.cpsi_cache });
    defer allocator.free(prefixed);

    var total_files = std.ArrayList([]u8){};
    defer {
        for (total_files.items) |item| {
            allocator.free(item);
        }
        total_files.deinit(allocator);
    }

    try search_files(allocator, &total_files, prefixed);

    try remove_recursive(total_files.items);
    std.debug.print("\ndone\n", .{});
}

fn search_files(allocator: std.mem.Allocator, all_file: *std.ArrayList([]u8), target_dir: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(target_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_dir, entry.name });

        if (entry.kind == .directory) {
            defer allocator.free(full_path);
            try search_files(allocator, all_file, full_path);
            continue;
        }

        try all_file.append(allocator, full_path);
    }
}

fn remove_recursive(target_files: [][]u8) !void {
    var current: usize = 0;

    for (target_files) |target_file| {
        current += 1;
        std.debug.print("\r\x1b[2Kclean: ({d}/{d}) {s}", .{ target_files.len, current, target_file });
        try std.fs.deleteFileAbsolute(target_file);
    }

    if (current == 0) {
        std.debug.print("Nothing to do", .{});
    }
}
