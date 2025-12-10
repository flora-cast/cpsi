const std = @import("std");
const package = @import("./structs.zig");

pub fn read_packages(allocator: std.mem.Allocator, path: []const u8) !*package.Packages {
    const packages = try allocator.create(package.Packages);
    errdefer allocator.destroy(&packages.*);

    var file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Package list not found.\n", .{});
            std.debug.print("try `cpsi update`\n", .{});
            std.debug.print("If you want to update the package list to a prefix, add the --prefix option to the update command.\n", .{});
            return error.PackagesBinFileNotFound;
        }
        return err;
    };
    defer file.close();
    const stat = try file.stat();
    const expected_size = @sizeOf(package.Packages);

    if (stat.size < expected_size) {
        return error.PackagesListTooSmall;
    }

    try file.deprecatedReader().readNoEof(std.mem.asBytes(&packages.*));
    return packages;
}
