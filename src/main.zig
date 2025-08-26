const std = @import("std");
const Smartcommit = @import("./smartCommit.zig");
const SmartAdd = @import("./smartAdd.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // Expect at least the program name and repo path.
    if (args.len < 2) {
        std.debug.print("Usage: {s} <repo_path> [-m <msg>] [-c]\n", .{args[0]});
        return;
    }

    const repo_path = args[1];
    var msg: ?[]const u8 = null;
    var do_commit = false;
    var do_add = false;

    // Parse remaining flags
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        // If -c is found, set the commit flag
        if (std.mem.eql(u8, args[i], "-c")) {
            do_commit = true;
        }
        if (std.mem.eql(u8, args[i], "-a")) {
            do_add = true;
        }
        // If -m is found, set the message flag
        else if (std.mem.eql(u8, args[i], "-m") and i + 1 < args.len) {
            msg = args[i + 1];
            i += 1;
        }
        // Unknown flags are ignored
    }

    // Show what we're doing
    std.debug.print("Running with repo={s}, do_commit={any}, msg={s}\n", .{ repo_path, do_commit, if (msg) |m| m else "(null)" });

    // Perform the commit if -c was passed
    if (do_commit) {
        const status = try Smartcommit.commit(alloc, repo_path, msg);
        std.debug.print("{s}\n", .{status});
    }
    if (do_add) {
        //add functionality here
        _ = try SmartAdd.add(alloc, repo_path);
    }
    if (!do_commit and !do_add) {
        std.debug.print("No action taken (use -c to commit or -a to Add).\n", .{});
    }
}
