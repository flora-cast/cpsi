const std = @import("std");
const installed = @import("installed");
const install = @import("install");
const constants = @import("constants");
const utils = @import("utils");
const search = @import("search");

const RemoveOptions = struct {
    prefix: ?[]const u8,
};

pub fn remove(allocator: std.mem.Allocator, packages: [][]const u8, option: RemoveOptions) !void {
    const prefix = option.prefix orelse "/";

    const prefix_realpath = try std.fs.realpathAlloc(allocator, prefix);
    defer allocator.free(prefix_realpath);

    if (!install.is_root()) {
        std.debug.print("Error: You must run this command as root\n", .{});
        std.process.exit(1);
    }

    for (packages) |pkg| {
        try remove_package(allocator, pkg, prefix_realpath);
    }
}

fn remove_package(allocator: std.mem.Allocator, package: []const u8, prefix: []const u8) !void {
    const installed_file = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ prefix, constants.cpsi_installed_dir, package });
    defer allocator.free(installed_file);

    std.debug.print("DEBUG: installed file: {s}\n", .{installed_file});

    const file = std.fs.openFileAbsolute(installed_file, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Package not found: {s}\n", .{package});
            std.process.exit(1);
        } else {
            const src = @src();
            std.debug.print("Error while open installed file: {any}\n", .{err});
            std.debug.print("For developers: [{d}:{d}] {s}\n", .{ src.line, src.column, src.fn_name });
            std.process.exit(1);
        }
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(content);

    var installed_struct = try installed.reader.parsePackage(allocator, content);
    defer installed_struct.deinit(allocator);

    // Do not remove if other packages depend on it
    const maybe_deps = try search.depends.search_depends_package(allocator, package, prefix);
    if (maybe_deps) |deps| {
        defer {
            for (deps) |*p| {
                p.deinit(allocator);
            }
            allocator.free(deps);
        }

        std.debug.print("Cannot remove {s}, required by: ", .{package});

        for (deps) |item| {
            std.debug.print("{s} ", .{item.name});
        }

        std.debug.print("\n", .{});
        return;
    }

    // Delete files/directories listed in pathlist
    for (installed_struct.pathlist) |path| {
        try std.posix.chdir(prefix);
        const path_file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Warning: could not open {s}: {any}\n", .{ path, err });
            continue;
        };
        const stat = path_file.stat() catch |err| {
            path_file.close();
            std.debug.print("Warning: could not stat {s}: {any}\n", .{ path, err });
            continue;
        };
        path_file.close();

        switch (stat.kind) {
            .file => {
                try deleteFileRecursive(path);
            },
            else => {},
        }
    }

    try std.fs.deleteFileAbsolute(installed_file);
}

pub fn is_dir_no_content(path: []const u8) !bool {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();

    while (try iter.next()) |_| {
        return false;
    }

    return true;
}

pub fn deleteFileRecursive(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    const stat = file.stat() catch |err| {
        file.close();
        return err;
    };
    file.close();

    if (stat.kind == .file) {
        try std.fs.cwd().deleteFile(path);
        if (std.fs.path.dirname(path)) |parent| {
            try deleteFileRecursive(parent);
        }
    } else if (stat.kind == .directory) {
        std.fs.cwd().deleteDir(path) catch |err| {
            if (err == error.DirNotEmpty) {
                return;
            } else {
                return err;
            }
        };
    }
}
