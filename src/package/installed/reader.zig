const structs = @import("./structs.zig");
const std = @import("std");

pub fn parsePackage(allocator: std.mem.Allocator, content: []const u8) !structs.InstalledPackage {
    var splited = std.mem.splitAny(u8, content, "\n");

    var name: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var pathlist: [][]const u8 = &.{};
    var depends: [][]const u8 = &.{};

    while (splited.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitAny(u8, line, "=");
        const key = parts.next() orelse continue;
        const value = parts.next() orelse continue;

        if (std.mem.eql(u8, key, "name")) {
            name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "version")) {
            version = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "pathlist")) {
            var splited_pathlist = std.mem.splitAny(u8, value, ":");
            var list = std.ArrayList([]const u8){};
            errdefer {
                for (list.items) |item| allocator.free(item);
                list.deinit(allocator);
            }
            while (splited_pathlist.next()) |path| {
                if (path.len == 0) continue;
                try list.append(allocator, try allocator.dupe(u8, path));
            }
            pathlist = try list.toOwnedSlice(allocator);
        } else if (std.mem.eql(u8, key, "depends")) {
            var splited_depends = std.mem.splitAny(u8, value, ":");
            var list = std.ArrayList([]const u8){};
            errdefer {
                for (list.items) |item| allocator.free(item);
                list.deinit(allocator);
            }
            while (splited_depends.next()) |dep| {
                if (dep.len == 0) continue;
                try list.append(allocator, try allocator.dupe(u8, dep));
            }
            depends = try list.toOwnedSlice(allocator);
        }
    }

    return structs.InstalledPackage{
        .name = name orelse return error.MissingField,
        .version = version orelse return error.MissingField,
        .pathlist = pathlist,
        .depends = depends,
    };
}

pub fn readPackage(allocator: std.mem.Allocator, file: []const u8) !structs.InstalledPackage {
    const file_opened = try std.fs.openFileAbsolute(file, .{});
    defer file_opened.close();
    const content = try file_opened.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(content);
    return parsePackage(allocator, content);
}
