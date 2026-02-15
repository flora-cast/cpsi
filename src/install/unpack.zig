const std = @import("std");
const zstig = @import("zstig");
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

pub fn decompressFileBuffered(
    input_path: []const u8,
    output_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    std.debug.print("input: {s}\noutput: {s}\n", .{ input_path, output_path });
    const input_file = try std.fs.openFileAbsolute(input_path, .{});
    defer input_file.close();

    const output_file = try std.fs.createFileAbsolute(output_path, .{});
    defer output_file.close();

    try zstig.decompressStream(
        input_file.deprecatedReader(),
        output_file.deprecatedWriter(),
        allocator,
    );
}

fn unpackTarZstd(
    allocator: std.mem.Allocator,
    package_file: []const u8,
    prefix: []const u8,
) ![][]const u8 {
    // Open package file

    const decompressed_tar_file = try std.fmt.allocPrint(allocator, "{s}.tmp", .{package_file});
    defer allocator.free(decompressed_tar_file);

    try decompressFileBuffered(package_file, decompressed_tar_file, allocator);

    // initialize pathlist
    var pathlist = std.ArrayList([]const u8){};
    defer pathlist.deinit(allocator);

    //errdefer {
    //   for (pathlist.items) |path| {
    //      allocator.free(path);
    //  }
    //  pathlist.deinit(allocator);
    //}

    // open prefix directory
    var prefix_dir = try std.fs.openDirAbsolute(prefix, .{});
    defer prefix_dir.close();

    try extractTar(allocator, &pathlist, decompressed_tar_file, prefix);

    return try pathlist.toOwnedSlice(allocator);
}

pub fn extractTar(allocator: std.mem.Allocator, extracted_array: *std.array_list.Aligned([]const u8, null), tar_path: []const u8, output_dir: []const u8) !void {
    const outDir = try std.fs.openDirAbsolute(output_dir, .{});
    const tar_file = try std.fs.openFileAbsolute(tar_path, .{});

    var buffer: [5460]u8 = undefined;
    var file_name_buffer: [std.fs.max_name_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_name_bytes]u8 = undefined;

    var tar_reader = tar_file.reader(&buffer);

    var iter = std.tar.Iterator.init(&tar_reader.interface, .{ .file_name_buffer = &file_name_buffer, .link_name_buffer = &link_name_buffer });

    while (try iter.next()) |entry| {
        const path = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(path);
        try extracted_array.append(allocator, path);

        std.debug.print("unpack(): unpacking {s}\n", .{path});

        switch (entry.kind) {
            .file => {
                const out_file = try outDir.createFile(entry.name, .{});
                defer out_file.close();

                var buf: [4096]u8 = undefined;

                var out_writer = out_file.writer(&buf);

                try iter.streamRemaining(entry, &out_writer.interface);
            },

            .directory => {
                try outDir.makePath(path);
                // Path already appended on line 128, don't append again
            },

            .sym_link => {
                if (std.fs.path.dirname(path)) |dir_name| {
                    try outDir.makePath(dir_name);
                }

                outDir.symLink(entry.link_name, path, .{}) catch |err| {
                    if (err == error.PathAlreadyExists) {
                        continue;
                    }

                    std.debug.print("Warning: Failed to create symlink {s} -> {s}: {}\n", .{ path, entry.link_name, err });
                };
            },
        }
    }
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
