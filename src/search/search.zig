const std = @import("std");
const repo_conf = @import("repos_conf");
const package = @import("package");
const reader = package.reader;
const structs = package.structs;
const constants = @import("constants");

pub const depends = @import("./depends.zig");

pub fn search(allocator: std.mem.Allocator, pkgs: [][]const u8) !void {
    const parsed_repos = repo_conf.parse_repos(allocator) catch |err| {
        std.debug.print("Failed to parse repos.toml: {any}\n", .{err});
        std.process.exit(1);
    };
    defer parsed_repos.deinit();

    var found = false;
    for (pkgs) |pkg| {
        for (parsed_repos.value.repo) |repo| {
            const read_repo = try std.fmt.allocPrint(allocator, "{s}/{s}/index", .{ constants.cpsi_repos, repo.name });
            defer allocator.free(read_repo);
            const readed = try reader.read_packages(allocator, read_repo);
            defer allocator.destroy(readed);
            var db = try structs.PackageDB.init(allocator, &readed.*);
            defer db.deinit();

            var search_result = try db.search(allocator, pkg);
            defer search_result.deinit(allocator);

            for (search_result.items) |result| {
                const found_pkg = result.package;
                std.debug.print("{s} ({s}) - v{s}: {s}\n", .{ found_pkg.name, repo.name, found_pkg.version, found_pkg.description });
                found = true;
                break;
            }
        }
    }

    if (!found) {
        std.debug.print("No packages found\n", .{});
    }
}
