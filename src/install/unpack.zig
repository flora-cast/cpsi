const std = @import("std");
const zstig = @import("zstig");
const package = @import("package");
const constants = @import("constants");
const utils = @import("utils");
const installed = @import("installed");
const c = @cImport({
    @cInclude("microtar.h");
});

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
    errdefer {
        for (pathlist.items) |path| {
            allocator.free(path);
        }
        pathlist.deinit(allocator);
    }

    // open prefix directory
    var prefix_dir = try std.fs.openDirAbsolute(prefix, .{});
    defer prefix_dir.close();

    try extractTar(allocator, &pathlist, decompressed_tar_file, prefix);

    return try pathlist.toOwnedSlice(allocator);
}

pub fn extractTar(allocator: std.mem.Allocator, extracted_array: *std.array_list.Aligned([]const u8, null), tar_path: []const u8, output_dir: []const u8) !void {
    var tar: c.mtar_t = undefined;
    var header: c.mtar_header_t = undefined;

    if (c.mtar_open(&tar, tar_path.ptr, "r") != c.MTAR_ESUCCESS) {
        return error.CannotOpenTar;
    }
    defer _ = c.mtar_close(&tar);

    while (c.mtar_read_header(&tar, &header) != c.MTAR_ENULLRECORD) {
        const filename: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(&header.name)));

        const filename_constu8: []const u8 = std.mem.sliceTo(filename, 0);
        std.debug.print("decomp: {s}\n", .{filename_constu8});
        const duped = try allocator.dupe(u8, filename_constu8);
        try extracted_array.append(allocator, duped);

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, filename });
        defer allocator.free(full_path);

        switch (header.type) {
            c.MTAR_TDIR => {
                // ディレクトリ作成
                try std.fs.cwd().makePath(full_path);
            },
            c.MTAR_TREG => {
                // 通常ファイル
                const dir = std.fs.path.dirname(full_path);
                if (dir) |d| try std.fs.cwd().makePath(d);

                const file = try std.fs.cwd().createFile(full_path, .{});
                defer file.close();

                const buffer = try allocator.alloc(u8, header.size);
                defer allocator.free(buffer);

                if (c.mtar_read_data(&tar, buffer.ptr, header.size) != c.MTAR_ESUCCESS) {
                    return error.ReadFailed;
                }
                try file.writeAll(buffer);
            },
            c.MTAR_TSYM => {
                // シンボリックリンク
                const target = std.mem.span(@as([*:0]const u8, @ptrCast(&header.linkname)));

                const dir = std.fs.path.dirname(full_path);
                if (dir) |d| try std.fs.cwd().makePath(d);

                // 既存のシンボリックリンクを削除（存在する場合）
                std.fs.cwd().deleteFile(full_path) catch {};

                try std.posix.symlink(target, full_path);
            },
            else => {
                // その他のタイプはスキップ
                std.debug.print("Skipping unsupported type: {}\n", .{header.type});
            },
        }

        _ = c.mtar_next(&tar);
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
