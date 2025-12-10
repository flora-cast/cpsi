const std = @import("std");
const curl = @import("curl");

const ProgressData = struct {
    file: *std.fs.File,
    downloaded: usize,
};

pub fn fetch_file(url: [:0]const u8, file: *std.fs.File) !void {
    std.debug.print("\n", .{});
    const alc = std.heap.page_allocator;
    const ca_bundle = try curl.allocCABundle(alc);
    defer ca_bundle.deinit();
    var easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    try easy.setUrl(url);
    try easy.setWritefunction(writeCallback);
    try easy.setMaxRedirects(32);
    try easy.setFollowLocation(true);

    var progress_data = ProgressData{
        .file = file,
        .downloaded = 0,
    };

    try easy.setWritedata(&progress_data);
    easy.timeout_ms = 180000;
    easy.user_agent = "cpsi-fetch/1.0";

    _ = try easy.perform();
    std.debug.print("\r\x1b[2K\x1b[1A", .{});
}

fn writeCallback(data: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.c) c_uint {
    const real_size = @as(usize, size) * @as(usize, nmemb);
    const progress_data = @as(*ProgressData, @ptrCast(@alignCast(user_data)));

    _ = progress_data.file.write(@as([*]const u8, @ptrCast(data))[0..real_size]) catch return 0;
    progress_data.downloaded += real_size;

    const downloaded_mb = @as(f64, @floatFromInt(progress_data.downloaded)) / 1024.0 / 1024.0;
    std.debug.print("\r\x1b[2Kdownloading: {d:.2} MB\n", .{downloaded_mb});
    std.debug.print("\r\x1b[1A", .{});

    return @intCast(real_size);
}
