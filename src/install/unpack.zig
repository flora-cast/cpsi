const std = @import("std");
const zstd = std.compress.zstd;
const package = @import("package");
const constants = @import("constants");
const utils = @import("utils");
const installed = @import("installed");

pub fn unpack(
    allocator: std.mem.Allocator,
    package_file: []const u8,
    package_info: package.structs.Package,
    prefix: []const u8,
) !void {
    const name = std.mem.sliceTo(&package_info.name, 0);
    const version = std.mem.sliceTo(&package_info.version, 0);

    // Create directory /var/lib/cpsi/installed directory if not exist
    const installed_dir = if (std.mem.eql(u8, prefix, "/"))
        constants.cpsi_installed_dir
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, constants.cpsi_installed_dir });

    defer if (!std.mem.eql(u8, prefix, "/")) allocator.free(installed_dir);
    try utils.makeDirAbsoluteRecursive(allocator, installed_dir);

    const installed_file = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ installed_dir, name });
    defer allocator.free(installed_file);

    var file = try std.fs.createFileAbsolute(installed_file, .{});
    defer file.close();

    // Unpack tar file and get extracted path list
    const pathlist = try unpackTarZstd(allocator, package_file, prefix);
    defer {
        for (pathlist) |path| {
            allocator.free(path);
        }
        allocator.free(pathlist);
    }

    // collect dependence packages
    var depends_list = std.ArrayList([]const u8){};
    defer depends_list.deinit(allocator);

    for (package_info.depend) |dep| {
        const dep_str = std.mem.sliceTo(&dep, 0);
        if (dep_str.len > 0) {
            try depends_list.append(allocator, dep_str);
        }
    }

    const installed_package = installed.structs.InstalledPackage{
        .name = name,
        .version = version,
        .pathlist = pathlist,
        .depends = depends_list.items,
    };

    try installed.writer.writePackageList(allocator, file, installed_package);
}

fn unpackTarZstd(
    allocator: std.mem.Allocator,
    package_file: []const u8,
    prefix: []const u8,
) ![][]const u8 {
    // Open package file
    const file = try std.fs.openFileAbsolute(package_file, .{ .mode = .read_only });
    defer file.close();

    var buffer_zstd: [2042]u8 = undefined;
    var reader = file.reader(&buffer_zstd);

    var window_buf: [zstd.default_window_len + zstd.block_size_max + 1]u8 = undefined;
    var zstd_stream = zstd.Decompress.init(&reader.interface, &window_buf, .{});
    const uncompressed_reader = &zstd_stream.reader;

    // initialize pathlist
    var pathlist = std.ArrayList([]const u8){};
    errdefer {
        for (pathlist.items) |path| {
            allocator.free(path);
        }
        pathlist.deinit(allocator);
    }

    // open prefix directory
    var prefix_dir = try std.fs.openDirAbsolute(prefix, .{});
    defer prefix_dir.close();

    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buf: [std.fs.max_name_bytes]u8 = undefined;

    var tar_iter = std.tar.Iterator.init(uncompressed_reader, .{ .file_name_buffer = &file_name_buf, .link_name_buffer = &link_name_buf });

    // process tar file
    while (try tar_iter.next()) |tar_file| {
        switch (tar_file.kind) {
            .directory => {
                try prefix_dir.makePath(tar_file.name);
                const path = try allocator.dupe(u8, tar_file.name);
                try pathlist.append(allocator, path);
            },
            .file => {
                if (std.fs.path.dirname(tar_file.name)) |dir_name| {
                    try prefix_dir.makePath(dir_name);
                }

                var out_file = try prefix_dir.createFile(tar_file.name, .{
                    .mode = tar_file.mode,
                });
                defer out_file.close();

                var buffer: [2 * 1024]u8 = undefined;

                var file_writer = out_file.writer(&buffer);
                try tar_iter.streamRemaining(tar_file, &file_writer.interface);
                const path = try allocator.dupe(u8, tar_file.name);
                try pathlist.append(allocator, path);
            },
            .sym_link => {
                // Check parent directory exists
                if (std.fs.path.dirname(tar_file.name)) |dir_name| {
                    try prefix_dir.makePath(dir_name);
                }

                // Create symlink
                prefix_dir.symLink(tar_file.link_name, tar_file.name, .{}) catch |err| {
                    if (err == error.PathAlreadyExists) {
                        continue;
                    }
                    std.debug.print("Warning: Failed to create symlink {s} -> {s}: {}\n", .{
                        tar_file.name,
                        tar_file.link_name,
                        err,
                    });
                };

                const path = try allocator.dupe(u8, tar_file.name);
                try pathlist.append(allocator, path);
            },
        }
    }

    return try pathlist.toOwnedSlice(allocator);
}

pub fn splitToArray(
    allocator: std.mem.Allocator,
    text: []const u8,
    delimiters: []const u8,
) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();

    var iter = std.mem.splitAny(u8, text, delimiters);
    while (iter.next()) |part| {
        if (part.len > 0) {
            try list.append(part);
        }
    }

    return try list.toOwnedSlice();
}
