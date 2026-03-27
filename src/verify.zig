const std = @import("std");

const c = @cImport({
    @cInclude("gmp.h");
});

const DATA_DIR = "data";
const TIP_PATH = "TIP";
const MIN_ID_LEN: usize = 16;

const VerifyError = error{InvalidCertificate};

const Factor = struct {
    base: []const u8,
    exp: c_ulong,
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

    var data_dir = try std.fs.cwd().openDir(DATA_DIR, .{ .iterate = true });
    defer data_dir.close();

    var iter = data_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const id = entry.name;
        if (id.len < MIN_ID_LEN or id.len > 64 or !isLowerHex(id)) {
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

fn verifyMath(cert: Cert) !void {
    std.debug.print("CHECK {s}\n", .{cert.prime});

    var prime: c.mpz_t = undefined;
    try mpzInitSetStrDec(cert.prime, &prime);
    defer c.mpz_clear(&prime);

    var witness: c.mpz_t = undefined;
    try mpzInitSetStrDec(cert.witness, &witness);
    defer c.mpz_clear(&witness);

    if (c.mpz_cmp_ui(&prime, 2) <= 0) return fail("prime must be > 2", .{});
    if (c.mpz_cmp_ui(&witness, 1) <= 0) return fail("witness must be > 1", .{});

    var gcd: c.mpz_t = undefined;
    c.mpz_init(&gcd);
    defer c.mpz_clear(&gcd);
    c.mpz_gcd(&gcd, &prime, &witness);
    if (c.mpz_cmp_ui(&gcd, 1) != 0) return fail("gcd(prime, witness) != 1", .{});

    var n_minus_one: c.mpz_t = undefined;
    c.mpz_init_set_ui(&n_minus_one, 1);
    defer c.mpz_clear(&n_minus_one);

    var one: c.mpz_t = undefined;
    c.mpz_init_set_ui(&one, 1);
    defer c.mpz_clear(&one);

    var factor_index: usize = 0;
    while (factor_index < cert.factors.len) : (factor_index += 1) {
        const f = cert.factors[factor_index];

        var base: c.mpz_t = undefined;
        try mpzInitSetStrDec(f.base, &base);
        defer c.mpz_clear(&base);

        if (c.mpz_cmp_ui(&base, 1) <= 0) return fail("factor must be > 1", .{});

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

    var expected_prime: c.mpz_t = undefined;
    c.mpz_init(&expected_prime);
    defer c.mpz_clear(&expected_prime);
    c.mpz_add_ui(&expected_prime, &n_minus_one, 1);
    if (c.mpz_cmp(&prime, &expected_prime) != 0) return fail("prime != product(factors) + 1", .{});

    var fermat: c.mpz_t = undefined;
    c.mpz_init(&fermat);
    defer c.mpz_clear(&fermat);
    c.mpz_powm(&fermat, &witness, &n_minus_one, &prime);
    if (c.mpz_cmp(&fermat, &one) != 0) return fail("witness^(prime-1) mod prime != 1", .{});

    factor_index = 0;
    while (factor_index < cert.factors.len) : (factor_index += 1) {
        const f = cert.factors[factor_index];

        var base: c.mpz_t = undefined;
        try mpzInitSetStrDec(f.base, &base);
        defer c.mpz_clear(&base);

        if (c.mpz_divisible_p(&n_minus_one, &base) == 0) return fail("factor does not divide prime-1", .{});

        var q: c.mpz_t = undefined;
        c.mpz_init(&q);
        defer c.mpz_clear(&q);
        c.mpz_divexact(&q, &n_minus_one, &base);

        var check: c.mpz_t = undefined;
        c.mpz_init(&check);
        defer c.mpz_clear(&check);
        c.mpz_powm(&check, &witness, &q, &prime);

        if (c.mpz_cmp(&check, &one) == 0) return fail("witness^((prime-1)/factor) mod prime == 1", .{});
        std.debug.print("  FACTOR {d}/{d}\n", .{ factor_index + 1, cert.factors.len });
    }
}

fn resolveInputPath(arena: std.mem.Allocator, arg: ?[]const u8) ![]const u8 {
    if (arg) |a| {
        if (std.mem.indexOfScalar(u8, a, '/')) |_| {
            return arena.dupe(u8, a);
        }
        return std.fs.path.join(arena, &[_][]const u8{ DATA_DIR, a });
    }

    const tip_raw = try std.fs.cwd().readFileAlloc(arena, TIP_PATH, 4096);
    const tip = std.mem.trim(u8, tip_raw, " \t\r\n");
    if (tip.len < MIN_ID_LEN or tip.len > 64 or !isLowerHex(tip)) {
        return fail("invalid TIP content", .{});
    }
    return std.fs.path.join(arena, &[_][]const u8{ DATA_DIR, tip });
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
    if (cert_id.len < MIN_ID_LEN or cert_id.len > 64 or !isLowerHex(cert_id)) {
        return fail("invalid certificate id from path: {s}", .{cert_id});
    }

    const bytes = try std.fs.cwd().readFileAlloc(arena, cert_path, std.math.maxInt(usize));
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
