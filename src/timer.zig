const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

/// A lightweight span timer for profiling install phases.
///
/// When `--timing` is active, `stop()` records the elapsed time for later
/// printing to stderr. When `-Dtrace` is set at build time, spans are also
/// collected for Chrome Trace Format JSON output.
pub const Timer = struct {
    label: []const u8,
    start_ns: i128,
    parent: *Trace,

    pub fn start(trace: *Trace, label: []const u8) Timer {
        return .{
            .label = label,
            .start_ns = std.time.nanoTimestamp(),
            .parent = trace,
        };
    }

    pub fn stop(self: *Timer) void {
        const end_ns = std.time.nanoTimestamp();
        const elapsed_ns = end_ns - self.start_ns;

        if (self.parent.enabled) {
            self.parent.timing_spans.append(self.parent.allocator, .{
                .label = self.label,
                .elapsed_ns = elapsed_ns,
            }) catch {};
        }

        if (build_options.trace) {
            if (self.parent.trace_enabled) {
                const start_us: i64 = @intCast(@divTrunc(self.start_ns - self.parent.process_start, 1000));
                const dur_us: i64 = @intCast(@divTrunc(elapsed_ns, 1000));
                self.parent.trace_spans.append(self.parent.allocator, .{
                    .name = self.label,
                    .ts = start_us,
                    .dur = dur_us,
                }) catch {};
            }
        }
    }
};

/// A named timing entry recorded when `--timing` is active.
const TimingSpan = struct {
    label: []const u8,
    elapsed_ns: i128,
};

/// A Chrome Trace Format span recorded when `-Dtrace` is set.
const TraceSpan = struct {
    name: []const u8,
    ts: i64, // microseconds from process start
    dur: i64, // duration in microseconds
};

/// Collects timing data and optional trace spans across an operation.
pub const Trace = struct {
    enabled: bool, // --timing flag
    trace_enabled: bool, // comptime -Dtrace (runtime toggle)
    allocator: Allocator,
    process_start: i128,
    timing_spans: std.ArrayListUnmanaged(TimingSpan),
    trace_spans: std.ArrayListUnmanaged(TraceSpan),
    formula_name: []const u8,

    pub fn init(allocator: Allocator, timing: bool) Trace {
        return .{
            .enabled = timing,
            .trace_enabled = build_options.trace,
            .allocator = allocator,
            .process_start = std.time.nanoTimestamp(),
            .timing_spans = .{},
            .trace_spans = .{},
            .formula_name = "",
        };
    }

    pub fn deinit(self: *Trace) void {
        self.timing_spans.deinit(self.allocator);
        self.trace_spans.deinit(self.allocator);
    }

    /// Print the timing breakdown to stderr.
    pub fn printTimings(self: *const Trace) void {
        if (!self.enabled or self.timing_spans.items.len == 0) return;

        var err_buf: [4096]u8 = undefined;
        var ew = std.fs.File.stderr().writer(&err_buf);
        const stderr = &ew.interface;

        stderr.print("\n==> Timing: {s}\n", .{self.formula_name}) catch return;

        for (self.timing_spans.items) |span| {
            const ms = @divTrunc(span.elapsed_ns, 1_000_000);
            stderr.print("  {s:<16} {d}ms\n", .{ span.label, ms }) catch return;
        }

        stderr.flush() catch {};
    }

    /// Write Chrome Trace Format JSON to the given path.
    pub fn writeTraceFile(self: *const Trace, path: []const u8) void {
        if (!build_options.trace) return;
        if (self.trace_spans.items.len == 0) return;

        const file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();

        var buf: [8192]u8 = undefined;
        var bw = file.writer(&buf);
        const w = &bw.interface;

        w.print("[\n", .{}) catch return;

        for (self.trace_spans.items, 0..) |span, i| {
            if (i > 0) {
                w.print(",\n", .{}) catch return;
            }
            w.print(
                \\  {{"name":"{s}","ph":"X","ts":{d},"dur":{d},"pid":1,"tid":1}}
            , .{ span.name, span.ts, span.dur }) catch return;
        }

        w.print("\n]\n", .{}) catch return;
        w.flush() catch return;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "timer start and stop records timing span" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    var trace = Trace.init(allocator, true);
    defer trace.deinit();

    var t = Timer.start(&trace, "test_phase");
    t.stop();

    try std.testing.expectEqual(@as(usize, 1), trace.timing_spans.items.len);
    try std.testing.expectEqualStrings("test_phase", trace.timing_spans.items[0].label);
    try std.testing.expect(trace.timing_spans.items[0].elapsed_ns >= 0);
}

test "timer no-op when timing disabled" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    var trace = Trace.init(allocator, false);
    defer trace.deinit();

    var t = Timer.start(&trace, "ignored");
    t.stop();

    try std.testing.expectEqual(@as(usize, 0), trace.timing_spans.items.len);
}

test "trace init sets fields correctly" {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const allocator = gpa_instance.allocator();

    var trace = Trace.init(allocator, true);
    defer trace.deinit();

    try std.testing.expect(trace.enabled);
    try std.testing.expectEqual(build_options.trace, trace.trace_enabled);
    try std.testing.expectEqual(@as(usize, 0), trace.timing_spans.items.len);
}
