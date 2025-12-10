const std = @import("std");
const constants = @import("constants");
const repos_conf = @import("repos_conf");
const fetch = @import("fetch");
const hash = @import("hash");
const info = @import("info").info;
const utils = @import("utils");
const chroot = @import("scripts").chroot;

const UpdateOptions = struct {
    prefix: ?[]const u8 = null,
};

pub fn update_repo(allocator: std.mem.Allocator, options: UpdateOptions) !void {
    if (!is_root()) {
        std.debug.print("Error: You must run this command as root\n", .{});
        std.process.exit(1);
    }

    var prefix = options.prefix;

    if (options.prefix == null) {
        prefix = try allocator.dupe(u8, "/");
    } else {
        prefix = std.fs.realpathAlloc(allocator, options.prefix.?) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    std.debug.print("Error: Prefix directory not found\n", .{});
                    std.process.exit(1);
                },
                else => {
                    std.debug.print("Error: Failed to resolve prefix directory: {any}\n", .{err});
                    std.process.exit(1);
                },
            }
        };
    }
    defer allocator.free(prefix.?);

    try real_update(allocator, prefix.?);
}

pub fn real_update(alc: std.mem.Allocator, prefix: []const u8) !void {
    const repos = try repos_conf.parse_repos(alc);
    defer repos.deinit();

    for (repos.value.repo) |repo| {
        try info(alc, "fetch: {s}", .{repo.name});
        fetch_files(alc, prefix, repo.name, repo.url) catch |err| {
            std.debug.print("\nFailed to fetch {s}: {any}\n", .{ repo.name, err });
            return;
        };
        try info(alc, "check: {s}", .{repo.name});
        const result = try check_hash(alc, prefix, repo.name);
        if (!result) {
            std.debug.print("\nHash missmatch: {s}\n", .{repo.name});
        }
    }
    std.debug.print("\n", .{});
}

fn fetch_files(allocator: std.mem.Allocator, prefix: []const u8, repository_name: []const u8, repository_url: []const u8) !void {
    const repository_dir = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ prefix, constants.cpsi_repos, repository_name });
    defer allocator.free(repository_dir);

    const index_file = try std.fmt.allocPrint(allocator, "{s}/index", .{repository_dir});
    defer allocator.free(index_file);

    const index_b3 = try std.fmt.allocPrint(allocator, "{s}/index.b3", .{repository_dir});
    defer allocator.free(index_b3);

    try utils.makeDirAbsoluteRecursive(allocator, repository_dir);

    const url_index = try std.fmt.allocPrint(allocator, "{s}/index", .{repository_url});
    defer allocator.free(url_index);

    const url_b3 = try std.fmt.allocPrint(allocator, "{s}/index.b3", .{repository_url});
    defer allocator.free(url_b3);

    try utils.download(allocator, url_index, index_file);
    try utils.download(allocator, url_b3, index_b3);
}

pub fn check_hash(alc: std.mem.Allocator, prefix: []const u8, name: []const u8) !bool {
    const savedir = try std.fmt.allocPrint(alc, "{s}/{s}/{s}", .{ prefix, constants.cpsi_repos, name });
    defer alc.free(savedir);

    const index = try std.fmt.allocPrint(alc, "{s}/index", .{savedir});
    defer alc.free(index);

    const bin_b3 = try std.fmt.allocPrint(alc, "{s}/index.b3", .{savedir});
    defer alc.free(bin_b3);

    const bin_expected_file = try std.fs.openFileAbsolute(bin_b3, .{});
    const expected_hash = try bin_expected_file.readToEndAlloc(alc, 1024);
    defer alc.free(expected_hash);
    const trimmed = std.mem.trim(u8, expected_hash, &std.ascii.whitespace);

    const index_hash = try hash.gen_hash(alc, index);
    defer alc.free(index_hash);

    if (std.mem.eql(u8, index_hash, trimmed)) {
        return true;
    }
    return false;
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn is_root() bool {
    return std.os.linux.getuid() == 0;
}
