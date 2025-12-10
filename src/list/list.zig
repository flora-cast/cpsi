const std = @import("std");
const package = @import("package");
const constants = @import("constants");
const repos_conf = @import("repos_conf");
const utils = @import("utils");

pub fn list_packages(allocator: std.mem.Allocator) !void {
    var repos = try repos_conf.parse_repos(allocator);
    defer repos.deinit();

    const repository_list = repos.value.repo;

    for (repository_list) |repo| {
        const index_path = try std.fmt.allocPrint(allocator, "{s}/{s}/index", .{ constants.cpsi_repos, repo.name });
        defer allocator.free(index_path);

        const index = try package.reader.read_packages(allocator, index_path);
        defer allocator.destroy(index);
        var db = try package.structs.PackageDB.init(allocator, index);
        defer db.deinit();

        var sorted_packages = try db.listSorted(allocator);
        defer sorted_packages.deinit(allocator);

        for (sorted_packages.items) |pkg| {
            if (!utils.isValidPackage(pkg)) continue;
            std.debug.print("{s} ({s}) - {s}: {s}\n", .{ pkg.name, repo.name, pkg.version, pkg.description });
        }
    }
}
