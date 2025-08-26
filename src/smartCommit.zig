const std = @import("std");

const GitErr = error{ NoHead, GitFailed, NoUpstream, Offline, OutOfMemory };
pub const AheadBehind = struct { ahead: u32, behind: u32 };

//v2
pub fn commit(
    alloc: std.mem.Allocator,
    repo_path: []const u8,
    msg: ?[]const u8, // pass null to open editor
) GitErr![]const u8 {
    // 1) sanity‑check the index (only minimal checks)
    switch (try validateStaged(alloc, repo_path)) {
        .NoChanges => {
            // clean index; if you’re just behind, ff-sync now
            const ab0 = try aheadBehind(alloc, repo_path);
            if (ab0.behind > 0 and ab0.ahead == 0) {
                const res = try run(alloc, &[_][]const u8{
                    "git", "-C", repo_path, "merge", "--ff-only", "@{u}",
                });
                defer {
                    alloc.free(res.stdout);
                    alloc.free(res.stderr);
                }
                return "Fast-forwarded to upstream; working tree still clean.";
            }
            return "Nothing staged to commit";
        },
        .Conflicts => return "Resolve conflicts in index before committing",
        .Yes => {},
    }

    const head = try getHead(alloc, repo_path);
    defer alloc.free(head);

    const up = getUpstreamOrDefault(alloc, repo_path) catch |err| switch (err) {
        GitErr.NoUpstream => {
            try ensureCommit(alloc, repo_path, msg);
            return "Committed; no upstream branch configured";
        },
        else => |e| return e,
    };
    defer alloc.free(up);

    // 3) do the commit now
    try ensureCommit(alloc, repo_path, msg);

    // 4) report relation to upstream **after** the commit
    const ab = try aheadBehind(alloc, repo_path);
    std.debug.print("Ahead:{}  Behind:{}", .{ ab.ahead, ab.behind });

    if (ab.behind == 0 and ab.ahead == 0) {
        return "Committed on top of up‑to‑date upstream";
    } else if (ab.behind == 0 and ab.ahead > 0) {
        return "Committed; branch is ahead of upstream";
    } else if (ab.behind > 0 and ab.ahead == 0) {
        const res = try run(alloc, &[_][]const u8{
            "git",   "-C",        repo_path,
            "merge", "--ff-only", "@{u}",
        });
        defer {
            alloc.free(res.stdout);
            alloc.free(res.stderr);
        }

        const ab2 = try aheadBehind(alloc, repo_path);

        if (ab2.behind == 0) {
            return "Fast-forwarded to upstream; you are up to date.";
        } else {
            return "Still behind remote; someone pushed while you were syncing—retry or resolve.";
        }
    } else {
        return "Committed; branch has diverged from upstream";
    }
}

fn validateStaged(alloc: std.mem.Allocator, repo: []const u8) GitErr!StageIsOK {
    // Best-effort stat refresh; don't fail the whole operation on non-zero exit.
    {
        const r = try run(alloc, &[_][]const u8{
            "git", "-C", repo, "update-index", "-q", "--refresh",
        });
        defer {
            alloc.free(r.stdout);
            alloc.free(r.stderr);
        }
        try requireZeroExit(r);
    }

    if (!(try hasStagedChanges(alloc, repo))) return .NoChanges;
    if (try indexHasConflicts(alloc, repo)) return .Conflicts;
    return .Yes;
}

const StageIsOK = enum { Yes, NoChanges, Conflicts };

fn hasStagedChanges(alloc: std.mem.Allocator, repo: []const u8) GitErr!bool {
    const r = try run(alloc, &[_][]const u8{
        "git",                 "-C",       repo,
        "diff",                "--cached", "--name-only",
        "--ignore-submodules", "--",
    });
    defer {
        alloc.free(r.stdout);
        alloc.free(r.stderr);
    }
    try requireZeroExit(r);
    return r.stdout.len != 0;
}

fn indexHasConflicts(alloc: std.mem.Allocator, repo: []const u8) GitErr!bool {
    const r = try run(alloc, &[_][]const u8{
        "git", "-C", repo, "diff", "--cached", "--name-only", "--diff-filter=U",
    });
    defer {
        alloc.free(r.stdout);
        alloc.free(r.stderr);
    }
    try requireZeroExit(r);
    return r.stdout.len != 0;
}

fn ensureCommit(alloc: std.mem.Allocator, repo: []const u8, msg: ?[]const u8) GitErr!void {
    const cmd = if (msg) |m|
        &[_][]const u8{ "git", "-C", repo, "commit", "-m", m }
    else
        &[_][]const u8{ "git", "-C", repo, "commit" };

    const r = try run(alloc, cmd);
    defer {
        alloc.free(r.stdout);
        alloc.free(r.stderr);
    }
    try requireZeroExit(r);
}

//v2
fn getHead(alloc: std.mem.Allocator, repo_path: []const u8) GitErr![]u8 {
    const r = run(alloc, &[_][]const u8{
        "git", "-C", repo_path, "rev-parse", "--abbrev-ref", "HEAD",
    }) catch return GitErr.Offline;

    defer {
        alloc.free(r.stdout);
        alloc.free(r.stderr);
    }

    switch (r.term) {
        .Exited => |code| {
            if (code != 0) {
                if (std.mem.indexOf(u8, r.stderr, "unknown revision") != null or
                    std.mem.indexOf(u8, r.stderr, "ambiguous argument 'HEAD'") != null)
                    return GitErr.NoHead;
                return GitErr.GitFailed;
            }
        },
        else => return GitErr.GitFailed,
    }

    const trimmed = std.mem.trimRight(u8, r.stdout, "\r\n");
    const out = alloc.dupe(u8, trimmed) catch |e| switch (e) {
        error.OutOfMemory => return GitErr.OutOfMemory,
    };
    return out;
}

const ExecResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.ChildProcess.Term,
};

inline fn requireZeroExit(res: ExecResult) GitErr!void {
    if (res.term != .Exited) return GitErr.GitFailed;
    if (res.term.Exited != 0) return GitErr.GitFailed;
}

fn run(alloc: std.mem.Allocator, argv: []const []const u8) GitErr!ExecResult {
    for (argv) |arg| std.debug.print("{s} ", .{arg});
    std.debug.print("\n", .{});

    const r = std.ChildProcess.exec(.{
        .allocator = alloc,
        .argv = argv,
        .max_output_bytes = 1 << 20,
    }) catch |e| switch (e) {
        error.OutOfMemory => return GitErr.OutOfMemory,
        else => return GitErr.Offline,
    };

    return .{ .stdout = r.stdout, .stderr = r.stderr, .term = r.term };
}

fn aheadBehind(
    alloc: std.mem.Allocator,
    repo_path: []const u8,
) GitErr!AheadBehind {
    var remote: []const u8 = "origin";
    var remote_owned: ?[]u8 = null;
    defer if (remote_owned) |buf| alloc.free(buf);

    // --- detect upstream to choose the remote (best-effort) ---
    if (run(alloc, &[_][]const u8{
        "git",       "-C",           repo_path,
        "rev-parse", "--abbrev-ref", "--symbolic-full-name",
        "@{u}",
    }) catch null) |ur| {
        defer {
            alloc.free(ur.stdout);
            alloc.free(ur.stderr);
        }
        switch (ur.term) {
            .Exited => |code| if (code == 0 and ur.stdout.len != 0) {
                const spec = std.mem.trimRight(u8, ur.stdout, "\r\n");
                if (std.mem.indexOfScalar(u8, spec, '/')) |slash| {
                    const name = spec[0..slash];
                    const copy = alloc.dupe(u8, name) catch return GitErr.OutOfMemory;
                    remote_owned = copy;
                    remote = copy;
                }
            },
            .Signal => {},
            .Stopped => {},
            .Unknown => {},
        }
    }

    // --- best-effort fetch to refresh remote-tracking refs ---
    _ = run(alloc, &[_][]const u8{
        "git",     "-C",                      repo_path,
        "fetch",   "--quiet",                 "--tags",
        "--prune", "--no-recurse-submodules", remote,
    }) catch {};

    // --- compute ahead/behind against fresh @{u} ---
    const res = try run(alloc, &[_][]const u8{
        "git",         "-C",           repo_path,
        "rev-list",    "--left-right", "--count",
        "@{u}...HEAD",
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }
    try requireZeroExit(res);

    const line = std.mem.trimRight(u8, res.stdout, "\r\n");
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const behind_str = it.next() orelse return GitErr.GitFailed;
    const ahead_str = it.next() orelse return GitErr.GitFailed;

    const behind = std.fmt.parseInt(u32, behind_str, 10) catch return GitErr.GitFailed;
    const ahead = std.fmt.parseInt(u32, ahead_str, 10) catch return GitErr.GitFailed;

    return .{ .behind = behind, .ahead = ahead };
}

//v2 - FIXED: Removed duplicate code
fn getUpstreamOrDefault(alloc: std.mem.Allocator, repo_path: []const u8) GitErr![]u8 {
    const res = try run(alloc, &[_][]const u8{
        "git",       "-C",           repo_path,
        "rev-parse", "--abbrev-ref", "--symbolic-full-name",
        "@{u}",
    });
    defer {
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }

    switch (res.term) {
        .Exited => |code| {
            if (code != 0) {
                // Check for no upstream configuration
                if (std.mem.indexOf(u8, res.stderr, "no upstream") != null) {
                    return GitErr.NoUpstream;
                }
                return GitErr.GitFailed;
            }
        },
        else => return GitErr.GitFailed,
    }

    const trimmed = std.mem.trimRight(u8, res.stdout, "\r\n");
    const out = alloc.dupe(u8, trimmed) catch return GitErr.OutOfMemory;
    return out;
}

pub fn gitLogGraph(allocator: std.mem.Allocator, repo_path: []const u8) ![]u8 {
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "-C", repo_path, "log", "--graph", "--decorate" },
    });
    defer {
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }

    std.debug.print("stdout: {s}\n", .{result.stdout});
    std.debug.print("stderr: {s}\n", .{result.stderr});
    return result.stdout;
}
