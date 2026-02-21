const std = @import("std");
const installed = @import("installed");
const constants = @import("constants");

// Find packages that depend on specified packages
pub fn search_depends_package(allocator: std.mem.Allocator, package: []const u8, prefix: []const u8) !?installed.structs.InstalledPackageList {
    const installed_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, constants.cpsi_installed_dir });
    defer allocator.free(installed_dir);

    var dir = try std.fs.openDirAbsolute(installed_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();

    var array = std.ArrayList(installed.structs.InstalledPackage){};
    errdefer {
        for (array.items) |*item| {
            item.deinit(allocator);
        }
        array.deinit(allocator);
    }

    while (try iter.next()) |entry| {
        const full_path = try dir.realpathAlloc(allocator, entry.name);
        defer allocator.free(full_path);

        var installed_package = try installed.reader.readPackage(allocator, full_path);

        if (contains(installed_package.depends, package)) {
            try array.append(allocator, installed_package);
        } else {
            installed_package.deinit(allocator);
        }
    }

    if (array.items.len == 0) {
        return null;
    } else {
        return try array.toOwnedSlice(allocator);
    }
}

pub fn contains(target: [][]const u8, eql: []const u8) bool {
    for (target) |e| {
        if (std.mem.eql(u8, e, eql)) {
            return true;
        }
    }

    return false;
}
