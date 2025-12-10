const std = @import("std");
const toml = @import("toml");
const constants = @import("constants");
const repos_template = @embedFile("templates/repos_template.toml");
const utils = @import("utils");

pub const ReposConf = struct {
    repo: []Repository,
};

pub const Repository = struct {
    name: []const u8,
    url: []const u8,
};

pub fn parse_repos(allocator: std.mem.Allocator) !toml.Parsed(ReposConf) {
    var parser = toml.Parser(ReposConf).init(allocator);
    defer parser.deinit();

    if (!is_exists(constants.cpsi_repos_conf)) {
        try utils.makeDirAbsoluteRecursive(allocator, "/etc/cpsi");
        try std.fs.cwd().writeFile(.{ .data = repos_template, .sub_path = constants.cpsi_repos_conf });
    }

    const result = try parser.parseFile(constants.cpsi_repos_conf);

    return result;
}

fn is_exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
