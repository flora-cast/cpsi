const std = @import("std");
const builtin = @import("builtin");
const update = @import("update");
const install = @import("install");
const search = @import("search");
const list = @import("list");
const help_message = @embedFile("./templates/help_message");

// rowan -> pre-alpha | amary -> alpha | flower -> beta | wood -> stable
const VERSION = "0.1.0 (rowan)";
const ZIG_VERSION = builtin.zig_version_string;

const Command = enum {
    install,
    update,
    remove,
    search,
    list,
    info,
    clean,
    version,

    pub fn fromString(s: []const u8) ?Command {
        const map = std.StaticStringMap(Command).initComptime(.{
            .{ "install", .install },
            .{ "update", .update },
            .{ "remove", .remove },
            .{ "search", .search },
            .{ "list", .list },
            .{ "info", .info },
            .{ "clean", .clean },
            .{ "version", .version },
        });
        return map.get(s);
    }

    pub fn hasSubcommands(self: Command) bool {
        return switch (self) {
            else => false,
        };
    }
};

// コマンド固有のオプション
const CommandOptions = union(enum) {
    install: InstallOptions,
    update: UpdateOptions,
    search: SearchOptions,
    remove: RemoveOptions,
    none,

    const InstallOptions = struct {
        prefix: []const u8 = "/",
        disable_scripts: bool = false,
        hb_file: ?[]const u8 = null,
    };

    const UpdateOptions = struct {
        prefix: ?[]const u8 = null,
        force: bool = false,
    };

    const SearchOptions = struct {
        limit: ?usize = null,
        exact: bool = false,
    };

    const RemoveOptions = struct {
        prefix: ?[]const u8 = null,
        purge: bool = false,
    };
};

const ParsedCommand = struct {
    command: Command,
    options: CommandOptions = .none,
    positional_args: [][]const u8,
};

pub fn main() !void {
    var gpa: ?std.heap.GeneralPurposeAllocator(.{}) = null;
    var allocator: std.mem.Allocator = undefined;
    if (builtin.mode == .Debug) {
        gpa = std.heap.GeneralPurposeAllocator(.{}){};
        allocator = gpa.?.allocator();
    } else {
        allocator = std.heap.c_allocator;
    }
    defer {
        if (gpa) |*g| _ = g.deinit();
    }

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try display_help();
        std.process.exit(1);
    }

    const parsed = parseCommand(args[1..]) catch {
        try display_help();
        std.process.exit(1);
    } orelse {
        try display_help();
        std.process.exit(1);
    };

    try executeCommand(allocator, parsed);
}

fn parseCommand(args: [][:0]u8) !?ParsedCommand {
    if (args.len == 0) return null;

    const command = Command.fromString(args[0]) orelse {
        std.debug.print("unknown command: {s}\n", .{args[0]});
        return null;
    };

    var result = ParsedCommand{
        .command = command,
        .positional_args = &.{},
    };

    var arg_idx: usize = 1;

    switch (command) {
        .install => {
            result.options = .{ .install = try parseInstallOptions(args[arg_idx..], &arg_idx) };
        },
        .update => {
            result.options = .{ .update = try parseUpdateOptions(args[arg_idx..], &arg_idx) };
        },
        .search => {
            result.options = .{ .search = try parseSearchOptions(args[arg_idx..], &arg_idx) };
        },
        .remove => {
            result.options = .{ .remove = try parseRemoveOptions(args[arg_idx..], &arg_idx) };
        },
        else => {},
    }

    const tmp_allocator = std.heap.page_allocator;
    var positional_list = std.ArrayList([]const u8){};
    defer positional_list.deinit(tmp_allocator);

    while (arg_idx < args.len) {
        try positional_list.append(tmp_allocator, args[arg_idx]);
        arg_idx += 1;
    }

    result.positional_args = try positional_list.toOwnedSlice(tmp_allocator);
    return result;
}

fn parseInstallOptions(args: [][:0]u8, arg_idx: *usize) !CommandOptions.InstallOptions {
    var opts = CommandOptions.InstallOptions{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--prefix")) {
            if (i + 1 >= args.len) {
                std.debug.print("--prefix requires an argument\n", .{});
                return error.InvalidArgument;
            }
            opts.prefix = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--disable-scripts")) {
            opts.disable_scripts = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--hb-file")) {
            if (i + 1 >= args.len) {
                std.debug.print("--hb-file requires an argument\n", .{});
                return error.InvalidArgument;
            }
            opts.hb_file = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("--prefix <PREFIX>\tset installation directory\n", .{});
            std.debug.print("--disable-scripts\tdiasble postinstall and preinstall scripts\n", .{});
            std.debug.print("--help\t\t\tshow this help message\n", .{});
            std.posix.exit(0);
        } else {
            break;
        }
    }

    arg_idx.* += i;
    return opts;
}

fn parseUpdateOptions(args: [][:0]u8, arg_idx: *usize) !CommandOptions.UpdateOptions {
    var opts = CommandOptions.UpdateOptions{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--prefix")) {
            if (i + 1 >= args.len) {
                std.debug.print("--prefix requires an argument\n", .{});
                return error.InvalidArgument;
            }
            opts.prefix = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            opts.force = true;
            i += 1;
        } else {
            break;
        }
    }

    arg_idx.* += i;
    return opts;
}

fn parseSearchOptions(args: [][:0]u8, arg_idx: *usize) !CommandOptions.SearchOptions {
    var opts = CommandOptions.SearchOptions{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--limit")) {
            if (i + 1 >= args.len) {
                std.debug.print("--limit requires an argument\n", .{});
                return error.InvalidArgument;
            }
            opts.limit = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 2;
        } else if (std.mem.eql(u8, arg, "--exact")) {
            opts.exact = true;
            i += 1;
        } else {
            break;
        }
    }

    arg_idx.* += i;
    return opts;
}

fn parseRemoveOptions(args: [][:0]u8, arg_idx: *usize) !CommandOptions.RemoveOptions {
    var opts = CommandOptions.RemoveOptions{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--prefix")) {
            if (i + 1 >= args.len) {
                std.debug.print("--prefix requires an argument\n", .{});
                return error.InvalidArgument;
            }
            opts.prefix = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--purge")) {
            opts.purge = true;
            i += 1;
        } else {
            break;
        }
    }

    arg_idx.* += i;
    return opts;
}

fn executeCommand(allocator: std.mem.Allocator, parsed: ParsedCommand) !void {
    switch (parsed.command) {
        .install => {
            if (parsed.positional_args.len == 0) {
                std.debug.print("usage: install [options] <PACKAGES...>\n", .{});
                std.process.exit(1);
            }
            const opts = parsed.options.install;
            try install.install(allocator, parsed.positional_args, .{
                .prefix = opts.prefix,
                .disable_scripts = opts.disable_scripts,
            });
        },
        .update => {
            const opts = parsed.options.update;
            try update.update_repo(allocator, .{
                .prefix = opts.prefix,
            });
        },
        .search => {
            if (parsed.positional_args.len == 0) {
                std.debug.print("usage: search [options] <QUERY...>\n", .{});
                std.process.exit(1);
            }
            try search.search(allocator, parsed.positional_args);
        },
        .remove => {
            const opts = parsed.options.remove;
            std.debug.print("remove command not yet implemented (purge: {}, prefix: {?s})\n", .{ opts.purge, opts.prefix });
        },
        .list => {
            try list.list_packages(allocator);
        },
        .info => {
            std.debug.print("info command not yet implemented\n", .{});
        },
        .clean => {
            std.debug.print("clean command not yet implemented\n", .{});
        },
        .version => {
            std.debug.print("cpsi version {s}\n", .{VERSION});
            std.debug.print("with zig {s}\n", .{ZIG_VERSION});
        },
    }
}

fn display_help() !void {
    std.debug.print("{s}\n", .{help_message});
}
