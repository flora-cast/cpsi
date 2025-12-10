const std = @import("std");
const package = @import("package");
const repo_conf = @import("repos_conf");
const constants = @import("constants");
const reader = package.reader;

pub const DependencyNode = struct {
    name: []const u8,
    repo: repo_conf.Repository,
    dependencies: std.ArrayList([]const u8),
    is_user_requested: bool,

    pub fn deinit(self: *DependencyNode, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.dependencies.items) |dep| {
            allocator.free(dep);
        }
        self.dependencies.deinit(allocator);
    }
};

pub fn resolveDependencies(
    allocator: std.mem.Allocator,
    pkgs: [][]const u8,
    parsed_repos: *const repo_conf.ReposConf,
    install_packages: *std.StringHashMap(repo_conf.Repository),
    prefix: []const u8,
) !std.StringHashMap(DependencyNode) {
    var dependency_tree = std.StringHashMap(DependencyNode).init(allocator);
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iter = visited.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        visited.deinit();
    }

    var user_requested = std.StringHashMap(void).init(allocator);
    defer {
        var iter = user_requested.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        user_requested.deinit();
    }

    for (pkgs) |pkg| {
        const pkg_name = std.mem.sliceTo(pkg, 0);
        try user_requested.put(try allocator.dupe(u8, pkg_name), {});
    }

    for (pkgs) |pkg| {
        try resolveDependenciesRecursive(
            allocator,
            std.mem.sliceTo(pkg, 0),
            parsed_repos,
            &dependency_tree,
            &visited,
            install_packages,
            &user_requested,
            prefix,
        );
    }

    return dependency_tree;
}

fn resolveDependenciesRecursive(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    parsed_repos: *const repo_conf.ReposConf,
    dependency_tree: *std.StringHashMap(DependencyNode),
    visited: *std.StringHashMap(void),
    install_packages: *std.StringHashMap(repo_conf.Repository),
    user_requested: *std.StringHashMap(void),
    prefix: []const u8,
) !void {
    if (visited.contains(pkg_name)) {
        return;
    }

    try visited.put(try allocator.dupe(u8, pkg_name), {});

    // Find package
    var found_pkg: ?package.structs.Package = null;
    var found_repo: ?repo_conf.Repository = null;

    for (parsed_repos.repo) |repo| {
        const read_repo = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/index", .{ prefix, constants.cpsi_repos, repo.name });
        defer allocator.free(read_repo);

        const readed = reader.read_packages(allocator, read_repo) catch {
            std.posix.exit(1);
        };
        defer allocator.destroy(readed);

        var db = try package.structs.PackageDB.init(allocator, &readed.*);
        defer db.deinit();

        if (db.find(pkg_name)) |pkg| {
            found_pkg = pkg.*;
            found_repo = repo;
            break;
        }
    }

    if (found_pkg == null) {
        std.debug.print("Package not found: {s}\n", .{pkg_name});
        std.process.exit(1);
    }

    const pkg = found_pkg.?;
    const repo = found_repo.?;

    const duped_name = try allocator.dupe(u8, pkg_name);
    try install_packages.put(duped_name, repo);

    // dependency list
    var deps_list = std.ArrayList([]const u8){};

    for (pkg.depend) |dep| {
        if (isEmptyString(&dep)) break;

        const dep_name = std.mem.sliceTo(&dep, 0);
        if (dep_name.len > 0) {
            try deps_list.append(allocator, try allocator.dupe(u8, dep_name));

            // Recursively resolve dependencies
            try resolveDependenciesRecursive(
                allocator,
                dep_name,
                parsed_repos,
                dependency_tree,
                visited,
                install_packages,
                user_requested,
                prefix,
            );
        }
    }

    // Add to dependency tree
    const is_user_req = user_requested.contains(pkg_name);
    const node = DependencyNode{
        .name = try allocator.dupe(u8, pkg_name),
        .repo = repo,
        .dependencies = deps_list,
        .is_user_requested = is_user_req,
    };

    try dependency_tree.put(try allocator.dupe(u8, pkg_name), node);
}

pub fn printDependencyTree(
    allocator: std.mem.Allocator,
    pkgs: [][]const u8,
    dependency_tree: *const std.StringHashMap(DependencyNode),
) !void {
    var printed = std.StringHashMap(void).init(allocator);
    defer {
        var iter = printed.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        printed.deinit();
    }

    for (pkgs) |pkg| {
        const pkg_name = std.mem.sliceTo(pkg, 0);
        try printDependencyNode(allocator, pkg_name, dependency_tree, 0, &printed);
    }

    std.debug.print("\n", .{});
}

fn printDependencyNode(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    dependency_tree: *const std.StringHashMap(DependencyNode),
    depth: usize,
    printed: *std.StringHashMap(void),
) !void {
    const node = dependency_tree.get(pkg_name) orelse return;

    var indent = std.ArrayList(u8){};
    defer indent.deinit(allocator);

    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try indent.appendSlice(allocator, "  ");
    }

    const should_print = depth == 0 or !printed.contains(pkg_name);

    if (should_print) {
        if (depth == 0) {
            std.debug.print(" - {s}\n", .{pkg_name});
        } else if (depth >= 2) {
            std.debug.print("{s} -> {s}\n", .{ indent.items, pkg_name });
        } else {
            std.debug.print("{s} => {s}\n", .{ indent.items, pkg_name });
        }

        // Mark as printed
        if (depth > 0) {
            try printed.put(try allocator.dupe(u8, pkg_name), {});
        }

        // Display dependencies
        for (node.dependencies.items) |dep| {
            try printDependencyNode(allocator, dep, dependency_tree, depth + 1, printed);
        }
    }
}

pub fn getInstallOrder(
    allocator: std.mem.Allocator,
    pkgs: [][]const u8,
    dependency_tree: *const std.StringHashMap(DependencyNode),
) !std.ArrayList([]const u8) {
    var install_order = std.ArrayList([]const u8){};
    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iter = visited.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        visited.deinit();
    }

    // Topological sort (depth-first search)
    for (pkgs) |pkg| {
        const pkg_name = std.mem.sliceTo(pkg, 0);
        try topologicalSort(allocator, pkg_name, dependency_tree, &visited, &install_order);
    }

    return install_order;
}

fn topologicalSort(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    dependency_tree: *const std.StringHashMap(DependencyNode),
    visited: *std.StringHashMap(void),
    install_order: *std.ArrayList([]const u8),
) !void {
    if (visited.contains(pkg_name)) {
        return;
    }

    const node = dependency_tree.get(pkg_name) orelse return;

    // Recursively sort dependencies
    for (node.dependencies.items) |dep| {
        try topologicalSort(allocator, dep, dependency_tree, visited, install_order);
    }

    // Add this package
    try visited.put(try allocator.dupe(u8, pkg_name), {});
    try install_order.append(allocator, try allocator.dupe(u8, pkg_name));
}

fn isEmptyString(buf: []const u8) bool {
    return std.mem.indexOfScalar(u8, buf, 0) == 0;
}
