const std = @import("std");

const GitErr = error{ NoGit, BadStatus, GitFailed };

pub fn add(alloc: std.mem.Allocator, repo_path: []const u8) !void {
    const VERBOSE = true; // flip to false later

    if (VERBOSE) std.debug.print("[add] repo={s}\n", .{repo_path});

    // 0) Prove this is a repo (gives a clear error if not)
    try ensureGitRepo(alloc, repo_path);
    if (VERBOSE) std.debug.print("[add] ensureGitRepo: OK\n", .{});

    // 1) Refresh index stat info
    try runGitNoOut(alloc, repo_path, &[_][]const u8{ "update-index", "-q", "--refresh" });
    if (VERBOSE) std.debug.print("[add] update-index: OK\n", .{});

    // 2) Ask Git what changed (porcelain -z)
    const raw = try runGit(alloc, repo_path, &[_][]const u8{ "status", "--porcelain", "-z" });
    defer alloc.free(raw);

    if (VERBOSE) {
        std.debug.print("[add] porcelain(z) bytes={d}\n", .{raw.len});
        // print human-ish: show escaped with {s} can be ugly due to NULs, so dump hex for visibility
        std.debug.print("[add] porcelain(hex): ", .{});
        for (raw) |b| std.debug.print("{X:0>2} ", .{b});
        std.debug.print("\n", .{});
    }

    var list = try parsePorcelainZ(alloc, raw);
    defer list.deinit();

    if (VERBOSE) {
        std.debug.print("[add] entries={d}\n", .{list.items.len});
        for (list.items, 0..) |c, idx| {
            std.debug.print("[add] {d}: X={c} Y={c} old='{s}' path='{s}'\n", .{ idx, c.x, c.y, c.path_old, c.path });
        }
    }

    // 3) Stage what’s needed (and tell us how many)
    const counts = try stageChanges(alloc, repo_path, list.items);
    if (VERBOSE) {
        std.debug.print("[add] staged: add={d}, rm={d}\n", .{ counts.added, counts.removed });
    }

    // 4) Show after-status so you can see the effect immediately
    const after = try runGit(alloc, repo_path, &[_][]const u8{ "status", "--short" });
    defer alloc.free(after);
    std.debug.print("[add] git status --short AFTER:\n{s}\n", .{after});
}

// ----- helpers -----

fn isDotEntry(path: []const u8) bool {
    // never treat .git as a candidate
    if (std.mem.startsWith(u8, path, ".git/") or std.mem.eql(u8, path, ".git"))
        return false;

    const base = std.fs.path.basename(path);
    return base.len > 0 and base[0] == '.';
}

fn askYesNoDefaultNo(prompt: []const u8) !bool {
    const out = std.io.getStdOut().writer();
    const inp = std.io.getStdIn().reader();

    try out.print("{s} [y/N]: ", .{prompt});

    var buf: [64]u8 = undefined;
    const n = try inp.readUntilDelimiterOrEof(&buf, '\n');
    if (n == null or n.?.len == 0) return false;

    const first = std.ascii.toLower(n.?[0]);
    return first == 'y';
}
fn filterDotfilesSimple(
    alloc: std.mem.Allocator,
    to_add: *std.ArrayList([]const u8),
    to_rm: *std.ArrayList([]const u8),
) !void {
    // quick scan: any dotfiles at all?
    var found_dot = false;
    for (to_add.items) |p| if (isDotEntry(p)) {
        found_dot = true;
        break;
    };
    if (!found_dot) for (to_rm.items) |p| if (isDotEntry(p)) {
        found_dot = true;
        break;
    };
    if (!found_dot) return;

    const include = try askYesNoDefaultNo("Dotfiles detected (e.g. .env, .vscode). Include them?");
    if (include) return;

    // user said NO → drop them from both lists
    var keep_add = std.ArrayList([]const u8).init(alloc);
    defer keep_add.deinit();
    try keep_add.ensureTotalCapacity(to_add.items.len);
    for (to_add.items) |p| if (!isDotEntry(p)) try keep_add.append(p);
    to_add.clearRetainingCapacity();
    try to_add.appendSlice(keep_add.items);

    var keep_rm = std.ArrayList([]const u8).init(alloc);
    defer keep_rm.deinit();
    try keep_rm.ensureTotalCapacity(to_rm.items.len);
    for (to_rm.items) |p| if (!isDotEntry(p)) try keep_rm.append(p);
    to_rm.clearRetainingCapacity();
    try to_rm.appendSlice(keep_rm.items);
}

fn runGit(alloc: std.mem.Allocator, repo_path: []const u8, tail_argv: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    try argv.appendSlice(&[_][]const u8{ "git", "-C", repo_path });
    try argv.appendSlice(tail_argv);

    const res = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = argv.items,
    });
    defer alloc.free(res.stderr);

    switch (res.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("GitFailed: argv={any}\nexit={d}\nstderr:\n{s}\n", .{ argv.items, code, res.stderr });
                alloc.free(res.stdout);
                return GitErr.GitFailed;
            }
        },
        else => {
            std.debug.print("GitFailed: abnormal termination. argv={any}\n", .{argv.items});
            alloc.free(res.stdout);
            return GitErr.GitFailed;
        },
    }
    return res.stdout;
}

fn runGitNoOut(alloc: std.mem.Allocator, repo_path: []const u8, tail: []const []const u8) !void {
    const out = try runGit(alloc, repo_path, tail);
    defer alloc.free(out);
}

fn ensureGitRepo(alloc: std.mem.Allocator, path: []const u8) !void {
    const res = try std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = &[_][]const u8{ "git", "-C", path, "rev-parse", "--is-inside-work-tree" },
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }
    var ok = false;
    switch (res.term) {
        .Exited => |code| {
            if (code == 0) {
                const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
                ok = std.mem.eql(u8, trimmed, "true");
            }
        },
        else => {},
    }
    if (!ok) return GitErr.NoGit;
}

const Change = struct { x: u8, y: u8, path_old: []const u8, path: []const u8 };

fn parsePorcelainZ(alloc: std.mem.Allocator, buf: []const u8) !std.ArrayList(Change) {
    var out = std.ArrayList(Change).init(alloc);
    var i: usize = 0;
    while (i < buf.len) {
        if (i + 2 > buf.len) break;
        const a = buf[i];
        const b = buf[i + 1];
        var j = i + 2;
        while (j < buf.len and buf[j] != ' ') : (j += 1) {}
        if (j >= buf.len) return GitErr.BadStatus;
        i = j + 1;

        const start = i;
        while (i < buf.len and buf[i] != 0) : (i += 1) {}
        if (i >= buf.len) return GitErr.BadStatus;
        const first = buf[start..i];
        i += 1;

        var ch: Change = .{ .x = a, .y = b, .path_old = &[_]u8{}, .path = first };
        if (a == 'R' or a == 'C') {
            const start2 = i;
            while (i < buf.len and buf[i] != 0) : (i += 1) {}
            if (i >= buf.len) return GitErr.BadStatus;
            ch.path_old = first;
            ch.path = buf[start2..i];
            i += 1;
        }
        try out.append(ch);
    }
    return out;
}

const StageCounts = struct { added: usize = 0, removed: usize = 0 };

fn stageChanges(alloc: std.mem.Allocator, repo_path: []const u8, changes: []const Change) !StageCounts {
    var to_add = std.ArrayList([]const u8).init(alloc);
    defer to_add.deinit();
    var to_rm = std.ArrayList([]const u8).init(alloc);
    defer to_rm.deinit();

    for (changes) |c| {
        if (c.x == '?' and c.y == '?') {
            try to_add.append(c.path);
            continue;
        } // untracked
        if (c.y == 'M' or c.x == 'A') {
            try to_add.append(c.path);
            continue;
        } // modified/add
        if (c.y == 'D') {
            try to_rm.append(c.path);
            continue;
        } // deleted in WD
        if (c.x == 'R' or c.x == 'C') {
            try to_add.append(c.path);
            continue;
        } // rename/copy
    }

    try filterDotfilesSimple(alloc, &to_add, &to_rm);

    var counts: StageCounts = .{};

    if (to_add.items.len > 0) {
        var argv = std.ArrayList([]const u8).init(alloc);
        defer argv.deinit();
        try argv.appendSlice(&[_][]const u8{ "add", "--" });
        try argv.appendSlice(to_add.items);
        try runGitNoOut(alloc, repo_path, argv.items);
        counts.added = to_add.items.len;
    }

    if (to_rm.items.len > 0) {
        var argv2 = std.ArrayList([]const u8).init(alloc);
        defer argv2.deinit();
        try argv2.appendSlice(&[_][]const u8{ "rm", "--cached", "--" });
        try argv2.appendSlice(to_rm.items);
        try runGitNoOut(alloc, repo_path, argv2.items);
        counts.removed = to_rm.items.len;
    }

    return counts;
}
