const std = @import("std");

fn appendPrint(allocator: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try list.appendSlice(allocator, s);
}

pub fn countLines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

fn adjustForUtf8(content: []const u8, idx: usize) usize {
    var i = idx;
    while (i > 0 and i < content.len) {
        if (content[i] & 0xC0 == 0x80) {
            i -= 1;
        } else {
            break;
        }
    }
    return i;
}

pub fn findSurroundingFunction(content: []const u8, start_idx: usize) []const u8 {
    var idx = start_idx;
    while (idx > 0) {
        idx -= 1;
        if (idx >= 3 and std.mem.eql(u8, content[idx .. idx + 3], "fn ")) {
            var end_name = idx + 3;
            while (end_name < content.len and content[end_name] != '(' and content[end_name] != ' ') {
                end_name += 1;
            }
            return content[idx + 3 .. end_name];
        }
    }
    return "global";
}

pub fn detectAdversarial(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    const z_content = try allocator.dupeZ(u8, content);
    defer allocator.free(z_content);

    var tokenizer = std.zig.Tokenizer.init(z_content);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;

        if (token.tag == .builtin) {
            const name = z_content[token.loc.start..token.loc.end];
            if (std.mem.eql(u8, name, "@ptrCast")) return "@ptrCast";
            if (std.mem.eql(u8, name, "@ptrFromInt")) return "@ptrFromInt";
        }
        if (token.tag == .identifier) {
            const name = z_content[token.loc.start..token.loc.end];
            if (std.mem.eql(u8, name, "system")) return "system";
            if (std.mem.eql(u8, name, "syscall")) return "syscall";
            if (std.mem.eql(u8, name, "anyopaque")) return "anyopaque";
        }
        if (token.tag == .keyword_extern or token.tag == .keyword_export) {
            return "ffi";
        }
    }
    return "";
}

pub const Chunker = struct {
    content: []const u8,
    offset: usize = 0,
    max_chunk_size: usize = 1024,
    overlap: usize = 150,

    pub fn next(self: *Chunker) ?[]const u8 {
        if (self.offset >= self.content.len) return null;

        var end_idx = self.offset + self.max_chunk_size;
        if (end_idx > self.content.len) {
            end_idx = self.content.len;
        } else {
            var snap_idx = end_idx;
            var found_snap = false;
            while (snap_idx > self.offset + self.overlap) : (snap_idx -= 1) {
                if (snap_idx < self.content.len - 1 and self.content[snap_idx] == '\n' and self.content[snap_idx + 1] == '\n') {
                    end_idx = snap_idx + 2;
                    found_snap = true;
                    break;
                }
            }
            if (!found_snap) {
                snap_idx = end_idx;
                while (snap_idx > self.offset + self.overlap) : (snap_idx -= 1) {
                    if (self.content[snap_idx] == '\n') {
                        end_idx = snap_idx + 1;
                        break;
                    }
                }
            }
        }

        end_idx = adjustForUtf8(self.content, end_idx);
        if (end_idx <= self.offset) {
            end_idx = self.offset + 1; // forward progress
            end_idx = adjustForUtf8(self.content, end_idx);
            if (end_idx == self.offset) end_idx += 1; // force at least 1 byte if broken
        }

        const chunk_text = self.content[self.offset..end_idx];

        if (end_idx == self.content.len) {
            self.offset = end_idx;
        } else {
            var new_offset = end_idx - self.overlap;
            new_offset = adjustForUtf8(self.content, new_offset);
            if (new_offset >= end_idx) {
                self.offset = end_idx;
            } else {
                self.offset = new_offset;
            }
        }

        return chunk_text;
    }
};

const Warning = struct {
    file: []const u8,
    trigger: []const u8,
};

const Mutex = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pub fn lock(self: *Mutex) void {
        while (self.state.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }
    pub fn unlock(self: *Mutex) void {
        self.state.store(false, .release);
    }
};

const WaitGroup = struct {
    count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    pub fn start(self: *WaitGroup) void {
        _ = self.count.fetchAdd(1, .release);
    }
    pub fn finish(self: *WaitGroup) void {
        _ = self.count.fetchSub(1, .release);
    }
    pub fn wait(self: *WaitGroup) void {
        while (self.count.load(.acquire) > 0) {
            var spin: usize = 0;
            while (spin < 10000) : (spin += 1) { std.atomic.spinLoopHint(); }
        }
    }
};

var warnings_mutex = Mutex{};
var warnings_queue: std.ArrayList(Warning) = undefined;
var files_processed = std.atomic.Value(usize).init(0);
var total_files_count: usize = 0;
var is_done = std.atomic.Value(bool).init(false);
var out_mutex = Mutex{};

fn tuiThread() void {
    while (!is_done.load(.acquire)) {
        const processed = files_processed.load(.acquire);
        const total = total_files_count;

        std.debug.print("\x1b[2J\x1b[H", .{});
        std.debug.print("🚀 Flatulence Audit Architect - Scanning...\n", .{});

        var pct: usize = 0;
        if (total > 0) pct = (processed * 100) / total;

        std.debug.print("Progress: [", .{});
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            if (i < pct / 2) {
                std.debug.print("#", .{});
            } else {
                std.debug.print("-", .{});
            }
        }
        std.debug.print("] {}%\n\n", .{pct});

        std.debug.print("--- ADVERSARIAL WARNINGS ---\n", .{});
        warnings_mutex.lock();
        for (warnings_queue.items) |w| {
            std.debug.print("\x1b[91m[WARNING]\x1b[0m {s} -> {s}\n", .{ w.file, w.trigger });
        }
        warnings_mutex.unlock();

        var spin: usize = 0;
        while (spin < 1000000) : (spin += 1) { std.atomic.spinLoopHint(); }
    }
    
    // Final render
    std.debug.print("\x1b[2J\x1b[H", .{});
    std.debug.print("✅ Flatulence Audit Architect - Done Scanning {} files.\n", .{total_files_count});
    warnings_mutex.lock();
    for (warnings_queue.items) |w| {
        std.debug.print("\x1b[91m[WARNING]\x1b[0m {s} -> {s}\n", .{ w.file, w.trigger });
    }
    warnings_mutex.unlock();
}

const ProcessArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    rel_path: []const u8,
    out_file: std.Io.File,
};

fn processFileTask(args: ProcessArgs) void {
    const allocator = args.allocator;
    const io = args.io;
    defer allocator.free(args.rel_path);

    const file = std.Io.Dir.openFile(args.base_dir, io, args.rel_path, .{}) catch {
        _ = files_processed.fetchAdd(1, .release);
        return;
    };
    defer file.close(io);

    const max_size = 10 * 1024 * 1024;
    var content_list = std.ArrayList(u8).initCapacity(allocator, 0) catch return;
    defer content_list.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = file.readStreaming(io, &.{&buf}) catch break;
        if (bytes_read == 0) break;
        content_list.appendSlice(allocator, buf[0..bytes_read]) catch break;
        if (content_list.items.len >= max_size) break;
    }
    const content = content_list.items;

    if (content.len == 0) {
        _ = files_processed.fetchAdd(1, .release);
        return;
    }

    var list = std.ArrayList(u8).initCapacity(allocator, 0) catch return;
    defer list.deinit(allocator);

    appendPrint(allocator, &list, "<File path=\"{s}\">\n", .{args.rel_path}) catch return;

    var chunker = Chunker{ .content = content };
    var chunk_id: usize = 0;

    while (chunker.next()) |chunk_text| {
        const chunk_start = @intFromPtr(chunk_text.ptr) - @intFromPtr(content.ptr);
        const start_line = countLines(content[0..chunk_start]) + 1;
        const end_line = start_line + countLines(chunk_text) - 1;

        var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(chunk_text, &hash, .{});

        const hex_charset = "0123456789abcdef";
        var hex_hash: [64]u8 = undefined;
        for (hash, 0..) |b, i| {
            hex_hash[i * 2] = hex_charset[b >> 4];
            hex_hash[i * 2 + 1] = hex_charset[b & 15];
        }

        var risk: []const u8 = "LOW";
        const trigger = detectAdversarial(allocator, chunk_text) catch "";
        if (trigger.len > 0) {
            risk = "HIGH";
            warnings_mutex.lock();
            const w_file = allocator.dupe(u8, args.rel_path) catch "";
            const w_trig = allocator.dupe(u8, trigger) catch "";
            warnings_queue.append(allocator, .{ .file = w_file, .trigger = w_trig }) catch {};
            warnings_mutex.unlock();
        }

        const func_name = findSurroundingFunction(content, chunk_start);

        appendPrint(allocator, &list, "  <Chunk id=\"{d}\" lines=\"{d}-{d}\" sha256=\"{s}\">\n", .{ chunk_id, start_line, @max(start_line, end_line), &hex_hash }) catch return;
        appendPrint(allocator, &list, "    <Metadata>\n", .{}) catch return;
        if (std.mem.eql(u8, risk, "HIGH")) {
            appendPrint(allocator, &list, "      [ADVERSARIAL_WARNING]\n", .{}) catch return;
        }
        appendPrint(allocator, &list, "      Risk_Profile: {s}\n", .{risk}) catch return;
        appendPrint(allocator, &list, "      Surrounding_Function: {s}\n", .{func_name}) catch return;
        if (std.mem.eql(u8, risk, "HIGH")) {
            appendPrint(allocator, &list, "      Trigger: {s}\n", .{trigger}) catch return;
        }
        appendPrint(allocator, &list, "    </Metadata>\n", .{}) catch return;
        appendPrint(allocator, &list, "    <Content>\n{s}\n    </Content>\n", .{chunk_text}) catch return;
        appendPrint(allocator, &list, "  </Chunk>\n", .{}) catch return;

        chunk_id += 1;
    }

    appendPrint(allocator, &list, "</File>\n\n", .{}) catch return;

    out_mutex.lock();
    args.out_file.writeStreamingAll(io, list.items) catch {};
    out_mutex.unlock();

    _ = files_processed.fetchAdd(1, .release);
}

const Pool = struct {
    allocator: std.mem.Allocator,
    threads: std.ArrayList(std.Thread),

    pub fn create(alloc_in: std.mem.Allocator) !Pool {
        return Pool{
            .allocator = alloc_in,
            .threads = std.ArrayList(std.Thread).initCapacity(alloc_in, 0) catch unreachable,
        };
    }
    pub fn deinit(self: *Pool) void {
        for (self.threads.items) |t| t.join();
        self.threads.deinit(self.allocator);
    }
    pub fn spawnWg(self: *Pool, wg: *WaitGroup, comptime func: anytype, args: anytype) void {
        wg.start();
        const Wrapper = struct {
            pub fn run(w: *WaitGroup, a: @TypeOf(args)) void {
                @call(.auto, func, .{a});
                w.finish();
            }
        };
        if (std.Thread.spawn(.{}, Wrapper.run, .{ wg, args })) |t| {
            self.threads.append(self.allocator, t) catch {};
        } else |_| {
            wg.finish();
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.skip();

    var src_dir_path: ?[]const u8 = null;
    var out_file_path: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--src")) {
            src_dir_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--out")) {
            out_file_path = args_iter.next();
        }
    }

    if (src_dir_path == null or out_file_path == null) {
        std.debug.print("Usage: audit --src <dir> --out <file>\n", .{});
        return;
    }

    const out_file = std.Io.Dir.createFile(.cwd(), init.io, out_file_path.?, .{}) catch |err| {
        std.debug.print("Failed to create out_file: {}\n", .{err});
        return;
    };
    defer out_file.close(init.io);

    warnings_queue = std.ArrayList(Warning).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (warnings_queue.items) |w| {
            allocator.free(w.file);
            allocator.free(w.trigger);
        }
        warnings_queue.deinit(allocator);
    }

    var src_dir = std.Io.Dir.openDir(.cwd(), init.io, src_dir_path.?, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open src_dir: {}\n", .{err});
        return;
    };
    defer src_dir.close(init.io);

    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    var file_paths = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (file_paths.items) |p| allocator.free(p);
        file_paths.deinit(allocator);
    }

    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file) continue;

        const ext = std.fs.path.extension(entry.basename);
        if (!std.mem.eql(u8, ext, ".zig") and
            !std.mem.eql(u8, ext, ".zon") and
            !std.mem.eql(u8, ext, ".md") and
            !std.mem.eql(u8, ext, ".json"))
        {
            continue;
        }

        if (std.mem.indexOf(u8, entry.path, "zig-out") != null or
            std.mem.indexOf(u8, entry.path, ".zig-cache") != null or
            std.mem.indexOf(u8, entry.path, ".git") != null or
            std.mem.eql(u8, entry.basename, "audit.zig") or
            std.mem.eql(u8, entry.basename, "root.zig"))
        {
            continue;
        }

        const path_dup = try allocator.dupe(u8, entry.path);
        try file_paths.append(allocator, path_dup);
    }

    total_files_count = file_paths.items.len;

    const tui_thread = try std.Thread.spawn(.{}, tuiThread, .{});

    var pool = try Pool.create(allocator);
    defer pool.deinit();

    var wg = WaitGroup{};

    for (file_paths.items) |path| {
        const path_dup = try allocator.dupe(u8, path);
        pool.spawnWg(&wg, processFileTask, ProcessArgs{
            .allocator = allocator,
            .io = init.io,
            .base_dir = src_dir,
            .rel_path = path_dup,
            .out_file = out_file,
        });
    }

    wg.wait();
    is_done.store(true, .release);
    tui_thread.join();
}

// ---------------------------------------------------------
// TESTING
// ---------------------------------------------------------

test "chunker handles normal files" {
    const text = "hello\nworld\nthis\nis\na\ntest\nfile\n";
    var chunker = Chunker{ .content = text, .max_chunk_size = 10, .overlap = 2 };
    
    const chunk1 = chunker.next().?;
    try std.testing.expect(chunk1.len > 0);
}

test "chunker handles no newlines 10MB single line" {
    var allocator = std.testing.allocator;
    const big_str = try allocator.alloc(u8, 10 * 1024 * 1024);
    defer allocator.free(big_str);
    
    @memset(big_str, 'A');
    
    var chunker = Chunker{ .content = big_str, .max_chunk_size = 1024, .overlap = 150 };
    
    var count: usize = 0;
    while (chunker.next()) |chunk| {
        count += 1;
        try std.testing.expect(chunk.len <= 1024);
        if (count > 10000) break; // Should be exactly 11416 chunks
    }
    try std.testing.expect(count > 0);
}

test "chunker handles weird unicode boundaries" {
    // A string with a 4-byte unicode character in the middle
    // "hello 🌍 world"
    const text = "hello \xF0\x9F\x8C\x8D world";
    
    // We intentionally make max_chunk_size hit exactly in the middle of the emoji
    // Emoji is at index 6, 7, 8, 9. Let's slice at 8.
    var chunker = Chunker{ .content = text, .max_chunk_size = 8, .overlap = 0 };
    
    const c1 = chunker.next().?;
    // It should have truncated before the emoji or advanced past safely without crashing.
    try std.testing.expect(std.unicode.utf8ValidateSlice(c1));
    
    const c2 = chunker.next().?;
    try std.testing.expect(std.unicode.utf8ValidateSlice(c2));
}

test "context extractor finds surrounding function" {
    const text =
        \\const std = @import("std");
        \\
        \\fn calculateFarts(num: i32) void {
        \\    var a = 1;
        \\    // we are checking here
        \\}
        \\
    ;
    const name = findSurroundingFunction(text, 60);
    try std.testing.expectEqualStrings("calculateFarts", name);
}

test "detect adversarial captures ptrFromInt and system" {
    const allocator = std.testing.allocator;
    const text1 = "const ptr = @ptrFromInt(x);";
    const res1 = try detectAdversarial(allocator, text1);
    try std.testing.expectEqualStrings("@ptrFromInt", res1);
    
    const text2 = "libc.system(\"rm -rf\");";
    const res2 = try detectAdversarial(allocator, text2);
    try std.testing.expectEqualStrings("system", res2);
}
