const std = @import("std");
const fetch = @import("fetch");
const package = @import("package");
const reader = package.reader;
const constants = @import("constants");
const repo_conf = @import("repos_conf");
const info = @import("info").info;
const utils = @import("utils");
const unpack = @import("unpack.zig");
const scripts = @import("scripts");
const dependencies = @import("dependencies.zig");
const hash = @import("hash");

pub const InstallOptions = struct {
    prefix: []const u8 = "/",
    disable_scripts: bool = false,
    hb_file: ?[]const u8 = null,
};

pub fn install(allocator: std.mem.Allocator, pkgs: [][]const u8, options: InstallOptions) !void {
    const prefix = std.fs.realpathAlloc(allocator, options.prefix) catch |err| {
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
    defer allocator.free(prefix);

    try real_install_package(allocator, pkgs, .{ .prefix = prefix, .disable_scripts = options.disable_scripts });
}

fn real_install_package(allocator: std.mem.Allocator, pkgs: [][]const u8, options: InstallOptions) !void {
    const prefix = options.prefix;
    const is_prefix = !std.mem.eql(u8, prefix, "/");

    if (!is_root()) {
        std.debug.print("Error: You must run this command as root\n", .{});
        std.process.exit(1);
    }

    const parsed_repos = repo_conf.parse_repos(allocator) catch |err| {
        std.debug.print("Failed to parse repos.toml: {any}\n", .{err});
        std.process.exit(1);
    };
    defer parsed_repos.deinit();

    // create cache directory
    const prefix_cache = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, constants.cpsi_cache });
    defer allocator.free(prefix_cache);
    defer deleteTree(prefix_cache);

    // prefix cache の作成
    try utils.makeDirAbsoluteRecursive(allocator, prefix_cache);

    var install_packages = std.StringHashMap(repo_conf.Repository).init(allocator);
    defer {
        var iter = install_packages.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        install_packages.deinit();
    }

    // === 依存関係を解決 ===
    var dependency_tree = try dependencies.resolveDependencies(
        allocator,
        pkgs,
        &parsed_repos.value,
        &install_packages,
        prefix,
    );
    defer {
        var iter = dependency_tree.iterator();
        while (iter.next()) |entry| {
            var node = entry.value_ptr;
            node.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        dependency_tree.deinit();
    }

    // Display dependency tree
    try dependencies.printDependencyTree(allocator, pkgs, &dependency_tree);

    var install_order = try dependencies.getInstallOrder(allocator, pkgs, &dependency_tree);
    defer {
        for (install_order.items) |item| {
            allocator.free(item);
        }
        install_order.deinit(allocator);
    }

    const total_packages = install_order.items.len;

    // fetch packages
    for (install_order.items) |package_name| {
        const repo = install_packages.get(package_name) orelse continue;

        try info(allocator, "fetch: {s}", .{package_name});

        // ------ URL -------
        // clos(binary) package
        const clos_url = try std.fmt.allocPrint(allocator, "{s}/packages/{s}.clos", .{ repo.url, package_name });
        defer allocator.free(clos_url);

        // hash file for <package>.clos
        const b3_url = try std.fmt.allocPrint(allocator, "{s}/packages/{s}.clos.b3", .{ repo.url, package_name });
        defer allocator.free(b3_url);

        // hb(script) package
        const hb_url = try std.fmt.allocPrint(allocator, "{s}/packages/{s}.hb", .{ repo.url, package_name });
        defer allocator.free(hb_url);

        // hash file for <package>.hb
        const hb_b3_url = try std.fmt.allocPrint(allocator, "{s}/packages/{s}.hb.b3", .{ repo.url, package_name });
        defer allocator.free(hb_b3_url);

        // ------- FILE LOCATION -------
        // <pkg>clos
        const hcl_file = try std.fmt.allocPrint(allocator, "{s}/{s}.clos", .{ prefix_cache, package_name });
        defer allocator.free(hcl_file);

        // .clos.b3
        const hash_file = try std.fmt.allocPrint(allocator, "{s}/{s}.clos.b3", .{ prefix_cache, package_name });
        defer allocator.free(hash_file);

        // .hb
        const hb_file = try std.fmt.allocPrint(allocator, "{s}/{s}.hb", .{ prefix_cache, package_name });
        defer allocator.free(hb_file);

        // .hb.b3
        const hb_hash_file = try std.fmt.allocPrint(allocator, "{s}/{s}.hb.b3", .{ prefix_cache, package_name });
        defer allocator.free(hb_hash_file);

        try utils.download(allocator, clos_url, hcl_file);
        try utils.download(allocator, hb_url, hb_file);
        std.debug.print("fetch: {s} - hash", .{package_name});
        try utils.download(allocator, b3_url, hash_file);
        try utils.download(allocator, hb_b3_url, hb_hash_file);
    }
    std.debug.print("\n", .{});

    // check integrity
    for (install_order.items, 0..) |package_name, i| {
        const current = i + 1;
        integrity_check(allocator, package_name, current, total_packages, prefix) catch |err| {
            std.debug.print("\r\x1b[2KError: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }
    std.debug.print("\n", .{});

    // === install packages ===
    for (install_order.items, 0..) |package_name, i| {
        const current = i + 1;
        const repo = install_packages.get(package_name) orelse continue;

        try info(allocator, "install: {s} ({d}/{d})", .{ package_name, current, total_packages });

        const pkg_info = try getPackageInfo(allocator, package_name, repo, prefix);

        const clos_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.clos", .{ prefix_cache, package_name });
        defer allocator.free(clos_file_path);

        const hb_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.hb", .{ prefix_cache, package_name });
        defer allocator.free(hb_file_path);

        // preinstall script
        if (!options.disable_scripts) {
            scripts.install.pre_install(allocator, hb_file_path, prefix, is_prefix) catch |err| {
                std.debug.print("Error in executing pre install script: {s}, Error: {s}\n", .{ package_name, @errorName(err) });
                std.process.exit(1);
            };
        }

        // unpack with prefix
        try unpack.unpack(allocator, clos_file_path, pkg_info, prefix);

        // postinstall script
        if (!options.disable_scripts) {
            scripts.install.post_install(allocator, hb_file_path, prefix, is_prefix) catch |err| {
                std.debug.print("Error in executing post install script: {s}, Error: {s}\n", .{ package_name, @errorName(err) });
                std.process.exit(1);
            };
        }
    }
    std.debug.print("\n", .{});

    std.debug.print("Installation completed successfully to: {s}\n", .{prefix});
}

// todo
fn install_from_file(allocator: std.mem.Allocator, hb_file: []const u8, clos_file: []const u8, prefix: []const u8, disable_scripts: bool) !void {
    const is_prefix = prefix.len == 1;

    if (!disable_scripts) {
        try scripts.install.pre_install(allocator, hb_file, prefix, is_prefix);
    }

    try unpack.unpack(allocator, hb_file, clos_file, prefix);
}

fn getPackageInfo(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    repo: repo_conf.Repository,
    prefix: []const u8,
) !package.structs.Package {
    const prefix_cache = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, constants.cpsi_repos });
    defer allocator.free(prefix_cache);
    const read_repo = try std.fmt.allocPrint(allocator, "{s}/{s}/index", .{ prefix_cache, repo.name });
    defer allocator.free(read_repo);

    const readed = try reader.read_packages(allocator, read_repo);
    defer allocator.destroy(readed);

    var db = try package.structs.PackageDB.init(allocator, &readed.*);
    defer db.deinit();

    if (db.find(pkg_name)) |pkg| {
        return pkg.*;
    }

    std.debug.print("Package not found: {s}\n", .{pkg_name});
    std.process.exit(1);
}

fn integrity_check(allocator: std.mem.Allocator, package_name: []const u8, current_index: usize, total_packages: usize, prefix: []const u8) !void {
    const prefix_cache = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, constants.cpsi_cache });
    defer allocator.free(prefix_cache);

    try info(allocator, "check: {s} ({d}/{d})", .{ package_name, current_index, total_packages });

    const target_file = try std.fmt.allocPrint(allocator, "{s}/{s}.clos", .{ prefix_cache, package_name });
    defer allocator.free(target_file);

    const b3_file = try std.fmt.allocPrint(allocator, "{s}/{s}.clos.b3", .{ prefix_cache, package_name });
    defer allocator.free(b3_file);

    const target_file_hb = try std.fmt.allocPrint(allocator, "{s}/{s}.hb", .{ prefix_cache, package_name });
    defer allocator.free(target_file_hb);

    const b3_file_hb = try std.fmt.allocPrint(allocator, "{s}/{s}.hb.b3", .{ prefix_cache, package_name });
    defer allocator.free(b3_file_hb);

    const result_hcl = try hasher(allocator, target_file, b3_file);
    const result_hb = try hasher(allocator, target_file_hb, b3_file_hb);

    if (!result_hb or !result_hcl) {
        std.debug.print("\nhash mismatch for package '{s}'\n", .{package_name});
        std.process.exit(1);
    }
}

fn hasher(allocator: std.mem.Allocator, target: []const u8, expected: []const u8) !bool {
    const expected_hash = try std.fs.cwd().readFileAlloc(allocator, expected, 1000);
    defer allocator.free(expected_hash);
    const trimmed = std.mem.trim(u8, expected_hash, &std.ascii.whitespace);

    const generated = try hash.gen_hash(allocator, target);
    defer allocator.free(generated);

    return std.mem.eql(u8, trimmed, generated);
}

fn exec_scripts(allocator: std.mem.Allocator, prefix: []const u8, package_name: []const u8) !void {
    _ = allocator;
    _ = prefix;
    _ = package_name;
}

fn is_root() bool {
    return std.os.linux.getuid() == 0;
}

fn deleteTree(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch |err| {
        std.debug.print("Delete file failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
