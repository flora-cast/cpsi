const std = @import("std");

pub const InstalledPackage = struct {
    name: []const u8,
    version: []const u8,
    depends: [][]const u8,
    pathlist: [][]const u8,

    pub fn deinit(self: *InstalledPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.name);

        for (self.depends) |dep| {
            allocator.free(dep);
        }
        allocator.free(self.depends);

        for (self.pathlist) |dep| {
            allocator.free(dep);
        }
        allocator.free(self.pathlist);
    }
};

pub const InstalledPackageList = []InstalledPackage;
