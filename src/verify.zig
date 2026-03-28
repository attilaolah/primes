const std = @import("std");

const c = @cImport({
    @cInclude("gmp.h");
});

const data_dir = "data";
const tip_path = "TIP";
const min_id_len: usize = 16;
const max_cert_size: usize = 10 * 1024 * 1024;

const VerifyError = error{InvalidCertificate};

const Factor = struct {
    base: []const u8,
    exp: c_ulong,
};

const FactorWorkerShared = struct {
    mutex: std.Thread.Mutex = .{},
    next_index: usize = 0,
    completed: usize = 0,
    failed: bool = false,
    failed_code: u8 = 0,
    failed_index: usize = 0,
};

const FactorWorkerCtx = struct {
    shared: *FactorWorkerShared,
    factors: []const Factor,
    prime_dec: []const u8,
    witness_dec: []const u8,
    n_minus_one_dec: []const u8,
};

const Cert = struct {
    id: []const u8,
    prime: []const u8,
    witness: []const u8,
    factors: []Factor,
};

fn fail(comptime fmt: []const u8, args: anytype) VerifyError {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.InvalidCertificate;
}

fn isLowerHex(s: []const u8) bool {
    for (s) |ch| {
        if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    }
    return true;
}

fn isCanonicalUnsignedDecimal(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s.len > 1 and s[0] == '0') return false;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn cmpDecimal(a: []const u8, b: []const u8) std.math.Order {
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return std.mem.order(u8, a, b);
}

fn parseExponent(s: []const u8) !c_ulong {
    if (!isCanonicalUnsignedDecimal(s)) return error.InvalidCertificate;
    const n = try std.fmt.parseInt(u64, s, 10);
    if (n > std.math.maxInt(c_ulong)) return error.InvalidCertificate;
    return @intCast(n);
}

fn mpzInitSetStrDec(s: []const u8, out: *c.mpz_t) !void {
    if (!isCanonicalUnsignedDecimal(s)) return error.InvalidCertificate;
    const z = try std.heap.c_allocator.dupeZ(u8, s);
    defer std.heap.c_allocator.free(z);
    if (c.mpz_init_set_str(out, z.ptr, 10) != 0) return error.InvalidCertificate;
}

fn sha256HexOfBytes(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const hex = try arena.alloc(u8, 64);
    const lut = "0123456789abcdef";
    var i: usize = 0;
    while (i < digest.len) : (i += 1) {
        const b = digest[i];
        hex[2 * i] = lut[b >> 4];
        hex[2 * i + 1] = lut[b & 0x0f];
    }
    return hex;
}

fn sha256HexOfDecimal(arena: std.mem.Allocator, dec: []const u8) ![]const u8 {
    return sha256HexOfBytes(arena, dec);
}

fn mpzToOwnedDecimal(arena: std.mem.Allocator, n: *const c.mpz_t) ![]const u8 {
    const approx_digits = c.mpz_sizeinbase(n, 10);
    const tmp = try arena.alloc(u8, approx_digits + 3);
    const p = c.mpz_get_str(@ptrCast(tmp.ptr), 10, n) orelse return error.OutOfMemory;
    const z: [*:0]u8 = @ptrCast(p);
    const s = std.mem.sliceTo(z, 0);
    return arena.dupe(u8, s);
}

fn parseCertBytes(arena: std.mem.Allocator, id: []const u8, bytes: []const u8) !Cert {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') {
        return fail("{s}: file must end with newline", .{id});
    }

    var prime: ?[]const u8 = null;
    var witness: ?[]const u8 = null;
    var factors = std.array_list.Managed(Factor).init(arena);

    var line_no: usize = 0;
    var saw_version = false;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line_raw| {
        if (line_raw.len == 0) continue;
        line_no += 1;

        if (line_no == 1) {
            if (!std.mem.eql(u8, line_raw, "V 1")) {
                return fail("{s}: first line must be 'V 1'", .{id});
            }
            saw_version = true;
            continue;
        }

        if (std.mem.startsWith(u8, line_raw, "P ")) {
            if (prime != null) return fail("{s}: duplicate P line", .{id});
            const p = line_raw[2..];
            if (!isCanonicalUnsignedDecimal(p)) return fail("{s}: invalid prime", .{id});
            prime = p;
            continue;
        }

        if (std.mem.startsWith(u8, line_raw, "W ")) {
            if (witness != null) return fail("{s}: duplicate W line", .{id});
            const w = line_raw[2..];
            if (!isCanonicalUnsignedDecimal(w)) return fail("{s}: invalid witness", .{id});
            witness = w;
            continue;
        }

        if (std.mem.startsWith(u8, line_raw, "F ")) {
            const rest = line_raw[2..];
            if (rest.len == 0) return fail("{s}: empty F line", .{id});

            if (std.mem.indexOfScalar(u8, rest, '^')) |k| {
                const b = rest[0..k];
                const e = rest[k + 1 ..];
                if (!isCanonicalUnsignedDecimal(b)) return fail("{s}: invalid factor base", .{id});
                const exp = try parseExponent(e);
                if (exp <= 1) return fail("{s}: exponent must be > 1", .{id});
                try factors.append(.{ .base = b, .exp = exp });
            } else {
                if (!isCanonicalUnsignedDecimal(rest)) return fail("{s}: invalid factor base", .{id});
                try factors.append(.{ .base = rest, .exp = 1 });
            }
            continue;
        }

        return fail("{s}: invalid line: {s}", .{ id, line_raw });
    }

    if (!saw_version) return fail("{s}: missing V 1", .{id});
    if (prime == null or witness == null) return fail("{s}: missing P or W", .{id});
    if (factors.items.len == 0) return fail("{s}: missing factors", .{id});

    var idx: usize = 1;
    while (idx < factors.items.len) : (idx += 1) {
        if (cmpDecimal(factors.items[idx - 1].base, factors.items[idx].base) != .lt) {
            return fail("{s}: factors must be strictly ascending", .{id});
        }
    }

    return .{
        .id = id,
        .prime = prime.?,
        .witness = witness.?,
        .factors = try factors.toOwnedSlice(),
    };
}

fn readDataIds(arena: std.mem.Allocator) !std.array_list.Managed([]const u8) {
    var ids = std.array_list.Managed([]const u8).init(arena);

    var data_dir_handle = try std.fs.cwd().openDir(data_dir, .{ .iterate = true });
    defer data_dir_handle.close();

    var iter = data_dir_handle.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const id = entry.name;
        if (id.len < min_id_len or id.len > 64 or !isLowerHex(id)) {
            return fail("invalid certificate filename in data/: {s}", .{id});
        }
        try ids.append(try arena.dupe(u8, id));
    }

    return ids;
}

fn ensureDirectDependenciesExist(
    arena: std.mem.Allocator,
    cert: Cert,
    data_ids: []const []const u8,
) !void {
    for (cert.factors) |f| {
        if (std.mem.eql(u8, f.base, "2")) continue;

        const dep_hash = try sha256HexOfDecimal(arena, f.base);
        var matches: usize = 0;

        for (data_ids) |id| {
            if (std.mem.startsWith(u8, dep_hash, id)) {
                matches += 1;
            }
        }

        if (matches == 0) return fail("missing dependency file for factor prime {s}", .{f.base});
        if (matches > 1) return fail("ambiguous dependency id for factor prime {s}", .{f.base});
    }
}

fn summarizeDecimal(value: []const u8) struct { head: []const u8, truncated: bool, digits: usize } {
    const max_head = 20;
    if (value.len <= max_head) {
        return .{ .head = value, .truncated = false, .digits = value.len };
    }
    return .{ .head = value[0..max_head], .truncated = true, .digits = value.len };
}

fn verifyMath(cert: Cert) !void {
    const s = summarizeDecimal(cert.prime);
    if (s.truncated) {
        std.debug.print("CHECK {s}... ({d} digits)\n", .{ s.head, s.digits });
    } else {
        std.debug.print("CHECK {s} ({d} digits)\n", .{ s.head, s.digits });
    }

    // SAFETY: GMP fully initializes mpz_t via mpzInitSetStrDec before any read.
    var prime: c.mpz_t = undefined;
    try mpzInitSetStrDec(cert.prime, &prime);
    defer c.mpz_clear(&prime);

    // SAFETY: GMP fully initializes mpz_t via mpzInitSetStrDec before any read.
    var witness: c.mpz_t = undefined;
    try mpzInitSetStrDec(cert.witness, &witness);
    defer c.mpz_clear(&witness);

    if (c.mpz_cmp_ui(&prime, 2) <= 0) return fail("prime must be > 2", .{});
    if (c.mpz_cmp_ui(&witness, 1) <= 0) return fail("witness must be > 1", .{});

    // SAFETY: GMP fully initializes mpz_t via mpz_init before any read.
    var gcd: c.mpz_t = undefined;
    c.mpz_init(&gcd);
    defer c.mpz_clear(&gcd);
    c.mpz_gcd(&gcd, &prime, &witness);
    if (c.mpz_cmp_ui(&gcd, 1) != 0) return fail("gcd(prime, witness) != 1", .{});

    // SAFETY: GMP fully initializes mpz_t via mpz_init_set_ui before any read.
    var n_minus_one: c.mpz_t = undefined;
    c.mpz_init_set_ui(&n_minus_one, 1);
    defer c.mpz_clear(&n_minus_one);

    // SAFETY: GMP fully initializes mpz_t via mpz_init_set_ui before any read.
    var one: c.mpz_t = undefined;
    c.mpz_init_set_ui(&one, 1);
    defer c.mpz_clear(&one);

    var factor_index: usize = 0;
    while (factor_index < cert.factors.len) : (factor_index += 1) {
        const f = cert.factors[factor_index];

        // SAFETY: GMP fully initializes mpz_t via mpzInitSetStrDec before any read.
        var base: c.mpz_t = undefined;
        try mpzInitSetStrDec(f.base, &base);
        defer c.mpz_clear(&base);

        if (c.mpz_cmp_ui(&base, 1) <= 0) return fail("factor must be > 1", .{});

        // SAFETY: GMP fully initializes mpz_t via mpz_init before any read.
        var factor_pow: c.mpz_t = undefined;
        c.mpz_init(&factor_pow);
        defer c.mpz_clear(&factor_pow);
        if (f.exp == 1) {
            c.mpz_set(&factor_pow, &base);
        } else {
            c.mpz_pow_ui(&factor_pow, &base, f.exp);
        }
        c.mpz_mul(&n_minus_one, &n_minus_one, &factor_pow);
    }

    // SAFETY: GMP fully initializes mpz_t via mpz_init before any read.
    var expected_prime: c.mpz_t = undefined;
    c.mpz_init(&expected_prime);
    defer c.mpz_clear(&expected_prime);
    c.mpz_add_ui(&expected_prime, &n_minus_one, 1);
    if (c.mpz_cmp(&prime, &expected_prime) != 0) return fail("prime != product(factors) + 1", .{});

    // SAFETY: GMP fully initializes mpz_t via mpz_init before any read.
    var fermat: c.mpz_t = undefined;
    c.mpz_init(&fermat);
    defer c.mpz_clear(&fermat);
    c.mpz_powm(&fermat, &witness, &n_minus_one, &prime);
    if (c.mpz_cmp(&fermat, &one) != 0) return fail("witness^(prime-1) mod prime != 1", .{});

    const prime_dec = try mpzToOwnedDecimal(std.heap.c_allocator, &prime);
    defer std.heap.c_allocator.free(prime_dec);
    const witness_dec = try mpzToOwnedDecimal(std.heap.c_allocator, &witness);
    defer std.heap.c_allocator.free(witness_dec);
    const n_minus_one_dec = try mpzToOwnedDecimal(std.heap.c_allocator, &n_minus_one);
    defer std.heap.c_allocator.free(n_minus_one_dec);

    var shared = FactorWorkerShared{};
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const thread_count = @max(@as(usize, 1), @min(cpu_count, cert.factors.len));

    var workers = try std.heap.c_allocator.alloc(std.Thread, thread_count);
    defer std.heap.c_allocator.free(workers);
    var ctxs = try std.heap.c_allocator.alloc(FactorWorkerCtx, thread_count);
    defer std.heap.c_allocator.free(ctxs);

    var t: usize = 0;
    while (t < thread_count) : (t += 1) {
        ctxs[t] = .{
            .shared = &shared,
            .factors = cert.factors,
            .prime_dec = prime_dec,
            .witness_dec = witness_dec,
            .n_minus_one_dec = n_minus_one_dec,
        };
        workers[t] = try std.Thread.spawn(.{}, factorWorkerMain, .{&ctxs[t]});
    }
    t = 0;
    while (t < thread_count) : (t += 1) workers[t].join();

    if (shared.failed) {
        switch (shared.failed_code) {
            1 => return fail("factor does not divide prime-1 (factor #{d})", .{shared.failed_index + 1}),
            2 => return fail("witness^((prime-1)/factor) mod prime == 1 (factor #{d})", .{shared.failed_index + 1}),
            else => return fail("factor worker failed (factor #{d})", .{shared.failed_index + 1}),
        }
    }
}

fn factorWorkerMain(ctx: *FactorWorkerCtx) void {
    // SAFETY: GMP fully initializes mpz_t via mpzInitSetStrDec before any read.
    var prime: c.mpz_t = undefined;
    mpzInitSetStrDec(ctx.prime_dec, &prime) catch {
        setFactorFailure(ctx.shared, 3, 0);
        return;
    };
    defer c.mpz_clear(&prime);

    // SAFETY: GMP fully initializes mpz_t via mpzInitSetStrDec before any read.
    var witness: c.mpz_t = undefined;
    mpzInitSetStrDec(ctx.witness_dec, &witness) catch {
        setFactorFailure(ctx.shared, 3, 0);
        return;
    };
    defer c.mpz_clear(&witness);

    // SAFETY: GMP fully initializes mpz_t via mpzInitSetStrDec before any read.
    var n_minus_one: c.mpz_t = undefined;
    mpzInitSetStrDec(ctx.n_minus_one_dec, &n_minus_one) catch {
        setFactorFailure(ctx.shared, 3, 0);
        return;
    };
    defer c.mpz_clear(&n_minus_one);

    // SAFETY: GMP fully initializes mpz_t via mpz_init_set_ui before any read.
    var one: c.mpz_t = undefined;
    c.mpz_init_set_ui(&one, 1);
    defer c.mpz_clear(&one);

    while (true) {
        var idx: usize = 0;
        {
            ctx.shared.mutex.lock();
            defer ctx.shared.mutex.unlock();
            if (ctx.shared.failed or ctx.shared.next_index >= ctx.factors.len) break;
            idx = ctx.shared.next_index;
            ctx.shared.next_index += 1;
        }

        const f = ctx.factors[idx];

        // SAFETY: GMP fully initializes mpz_t via mpzInitSetStrDec before any read.
        var base: c.mpz_t = undefined;
        if (mpzInitSetStrDec(f.base, &base)) |_| {} else |_| {
            setFactorFailure(ctx.shared, 3, idx);
            break;
        }
        defer c.mpz_clear(&base);

        if (c.mpz_divisible_p(&n_minus_one, &base) == 0) {
            setFactorFailure(ctx.shared, 1, idx);
            break;
        }

        // SAFETY: GMP fully initializes mpz_t via mpz_init before any read.
        var q: c.mpz_t = undefined;
        c.mpz_init(&q);
        defer c.mpz_clear(&q);
        c.mpz_divexact(&q, &n_minus_one, &base);

        // SAFETY: GMP fully initializes mpz_t via mpz_init before any read.
        var check: c.mpz_t = undefined;
        c.mpz_init(&check);
        defer c.mpz_clear(&check);
        c.mpz_powm(&check, &witness, &q, &prime);

        if (c.mpz_cmp(&check, &one) == 0) {
            setFactorFailure(ctx.shared, 2, idx);
            break;
        }

        var done: usize = 0;
        ctx.shared.mutex.lock();
        ctx.shared.completed += 1;
        done = ctx.shared.completed;
        ctx.shared.mutex.unlock();
        std.debug.print("  FACTOR {d}/{d}\n", .{ done, ctx.factors.len });
    }
}

fn setFactorFailure(shared: *FactorWorkerShared, code: u8, index: usize) void {
    shared.mutex.lock();
    defer shared.mutex.unlock();
    if (!shared.failed) {
        shared.failed = true;
        shared.failed_code = code;
        shared.failed_index = index;
    }
}

fn resolveInputPath(arena: std.mem.Allocator, arg: ?[]const u8) ![]const u8 {
    if (arg) |a| {
        if (std.mem.indexOfScalar(u8, a, '/')) |_| {
            return arena.dupe(u8, a);
        }
        return std.fs.path.join(arena, &[_][]const u8{ data_dir, a });
    }

    const tip_raw = try std.fs.cwd().readFileAlloc(arena, tip_path, 4096);
    const tip = std.mem.trim(u8, tip_raw, " \t\r\n");
    if (tip.len < min_id_len or tip.len > 64 or !isLowerHex(tip)) {
        return fail("invalid TIP content", .{});
    }
    return std.fs.path.join(arena, &[_][]const u8{ data_dir, tip });
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try std.process.argsWithAllocator(arena);
    defer args.deinit();
    _ = args.next();

    const arg1 = args.next();
    if (args.next() != null) {
        std.debug.print("usage: verify [<cert-id-or-path>]\n", .{});
        return;
    }

    const cert_path = try resolveInputPath(arena, arg1);
    const cert_id = std.fs.path.basename(cert_path);
    if (cert_id.len < min_id_len or cert_id.len > 64 or !isLowerHex(cert_id)) {
        return fail("invalid certificate id from path: {s}", .{cert_id});
    }

    const bytes = try std.fs.cwd().readFileAlloc(arena, cert_path, max_cert_size);
    if (bytes.len == max_cert_size) {
        return fail("{s}: certificate file is too large", .{cert_id});
    }
    const cert = try parseCertBytes(arena, cert_id, bytes);

    const prime_hash = try sha256HexOfDecimal(arena, cert.prime);
    if (!std.mem.startsWith(u8, prime_hash, cert.id)) {
        return fail("id does not match prime hash for prime {s}", .{cert.prime});
    }

    const data_ids = try readDataIds(arena);
    try ensureDirectDependenciesExist(arena, cert, data_ids.items);

    try verifyMath(cert);
    std.debug.print("OK\n", .{});
}
