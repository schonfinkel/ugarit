const std = @import("std");
const ugarit = @import("ugarit");
const structargs = @import("zigcli").structargs;

const Cli = struct {
    @"config-dir": ?[]const u8 = null,
    help: bool = false,
    version: bool = false,

    __commands__: union(enum) {
        @"source-add": struct {
            name: ?[]const u8 = null,
            label: ?[]const u8 = null,
            path: ?[]const u8 = null,
            target: ?[]const u8 = null,
            @"no-claude-sync": bool = false,
            ref: ?[]const u8 = null,
            help: bool = false,
        },
        @"source-sync": struct {
            help: bool = false,
        },
        link: struct {
            as: ?[]const u8 = null,
            force: bool = false,
            mkdir: bool = false,
            @"no-exclude": bool = false,
            help: bool = false,
        },
        unlink: struct {
            skill: ?[]const u8 = null,
            help: bool = false,
        },
        list: struct {
            source: ?[]const u8 = null,
            links: bool = false,
            help: bool = false,
        },

        pub const __messages__ = .{
            .@"source-add" = "Register and clone a Git repository source: <url>",
            .@"source-sync" = "Fetch and fast-forward sources, then repair links: [name|label]",
            .link = "Symlink a source skill: <source|label> <skill> <dest-dir...>",
            .unlink = "Remove managed links: <link-path>... | --skill <name>",
            .list = "List skills and link status: [skill]",
        };
    },

    pub const __shorts__ = .{ .help = .h };
    pub const __messages__ = .{
        .@"config-dir" = "Override the ugarit configuration directory",
        .help = "Print help",
        .version = "Print version",
    };
};

pub fn main(init: std.process.Init) !u8 {
    const a = init.gpa;
    const io = init.io;
    var parsed = structargs.parse(a, io, init.minimal.args, Cli, .{
        .version_string = "ugarit " ++ ugarit.app.version,
        .print_help_on_error = true,
    }) catch return 2;
    defer parsed.deinit();

    const stdout_file = std.Io.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const stderr_file = std.Io.File.stderr();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = stderr_file.writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    ugarit.git.init(init.environ_map) catch |err| {
        try report(stderr, err);
        try stderr.flush();
        return 1;
    };
    defer ugarit.git.deinit();

    const mode: ugarit.app.Mode = switch (parsed.options.__commands__) {
        .list => .read_only,
        else => .mutating,
    };
    var ctx = (if (mode == .read_only)
        ugarit.app.Context.initReadOnly(a, io, init.environ_map, parsed.options.@"config-dir", stdout, stderr)
    else
        ugarit.app.Context.init(a, io, init.environ_map, parsed.options.@"config-dir", stdout, stderr)) catch |err| {
        try report(stderr, err);
        try stderr.flush();
        return ugarit.app.diagnosticExitCode(ugarit.app.diagnostic(err));
    };
    defer ctx.deinit();

    const args = parsed.positional_arguments;
    const ok = dispatch(&ctx, parsed.options.__commands__, args) catch |err| {
        try report(stderr, err);
        try stdout.flush();
        try stderr.flush();
        return ugarit.app.diagnosticExitCode(ugarit.app.diagnostic(err));
    };
    try stdout.flush();
    try stderr.flush();
    return if (ok) 0 else 1;
}

fn dispatch(ctx: *ugarit.app.Context, command: @FieldType(Cli, "__commands__"), args: []const [:0]const u8) !bool {
    return switch (command) {
        .@"source-add" => |options| blk: {
            var parsed = ugarit.app.SourceAddOptions{
                .name = options.name,
                .label = options.label,
                .path = options.path,
                .target = options.target,
                .claude_sync = !options.@"no-claude-sync",
                .ref = options.ref,
            };
            var url: ?[]const u8 = null;
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                const slot: ?*?[]const u8 = if (std.mem.eql(u8, arg, "--name"))
                    &parsed.name
                else if (std.mem.eql(u8, arg, "--label"))
                    &parsed.label
                else if (std.mem.eql(u8, arg, "--path"))
                    &parsed.path
                else if (std.mem.eql(u8, arg, "--target"))
                    &parsed.target
                else if (std.mem.eql(u8, arg, "--ref"))
                    &parsed.ref
                else
                    null;
                if (slot) |field| {
                    i += 1;
                    if (i == args.len) return error.Usage;
                    field.* = args[i];
                } else if (std.mem.eql(u8, arg, "--no-claude-sync")) {
                    parsed.claude_sync = false;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    return error.Usage;
                } else if (url == null) {
                    url = arg;
                } else return error.Usage;
            }
            try ugarit.app.sourceAdd(ctx, url orelse return error.Usage, parsed);
            break :blk true;
        },
        .@"source-sync" => blk: {
            if (args.len > 1 or (args.len == 1 and std.mem.startsWith(u8, args[0], "--"))) return error.Usage;
            break :blk try ugarit.app.sourceSync(ctx, if (args.len == 1) args[0] else null);
        },
        .link => |options| blk: {
            var parsed = ugarit.app.LinkOptions{
                .as = options.as,
                .force = options.force,
                .mkdir = options.mkdir,
                .no_exclude = options.@"no-exclude",
            };
            var operands: std.ArrayList([]const u8) = .empty;
            defer operands.deinit(ctx.a);
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--as")) {
                    i += 1;
                    if (i == args.len) return error.Usage;
                    parsed.as = args[i];
                } else if (std.mem.eql(u8, arg, "--force")) {
                    parsed.force = true;
                } else if (std.mem.eql(u8, arg, "--mkdir")) {
                    parsed.mkdir = true;
                } else if (std.mem.eql(u8, arg, "--no-exclude")) {
                    parsed.no_exclude = true;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    return error.Usage;
                } else try operands.append(ctx.a, arg);
            }
            if (operands.items.len < 3) return error.Usage;
            break :blk try ugarit.app.link(ctx, operands.items[0], operands.items[1], operands.items[2..], parsed);
        },
        .unlink => |options| blk: {
            var skill = options.skill;
            var paths: std.ArrayList([]const u8) = .empty;
            defer paths.deinit(ctx.a);
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--skill")) {
                    i += 1;
                    if (i == args.len) return error.Usage;
                    skill = args[i];
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    return error.Usage;
                } else try paths.append(ctx.a, arg);
            }
            break :blk try ugarit.app.unlink(ctx, paths.items, skill);
        },
        .list => |options| blk: {
            var parsed = ugarit.app.ListOptions{ .source = options.source, .links = options.links };
            var query: ?[]const u8 = null;
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--source")) {
                    i += 1;
                    if (i == args.len) return error.Usage;
                    parsed.source = args[i];
                } else if (std.mem.eql(u8, arg, "--links")) {
                    parsed.links = true;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    return error.Usage;
                } else if (query == null) {
                    query = arg;
                } else return error.Usage;
            }
            try ugarit.app.list(ctx, query, .{
                .source = parsed.source,
                .links = parsed.links,
            });
            break :blk true;
        },
    };
}

fn report(writer: *std.Io.Writer, err: anyerror) !void {
    try writer.print("ugarit: {s}", .{ugarit.app.diagnosticMessage(ugarit.app.diagnostic(err))});
    if (err == error.Git and ugarit.git.lastMessage().len != 0) {
        try writer.writeAll(": ");
        try ugarit.config.redact(writer, ugarit.git.lastMessage());
    }
    try writer.writeAll("\n");
}
