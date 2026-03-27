const std = @import("std");

const c = @cImport({
    @cInclude("gmp.h");
});

const VerifyError = error{InvalidCertificate};

fn fail(comptime fmt: []const u8, args: anytype) VerifyError {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.InvalidCertificate;
}

fn mpzInitSetUi(v: *c.mpz_t, n: c_ulong) void {
    c.mpz_init_set_ui(v, n);
}

fn parseMpz(allocator: std.mem.Allocator, value: std.json.Value, out: *c.mpz_t) !void {
    switch (value) {
        .number_string => |s| {
            const z = try allocator.dupeZ(u8, s);
            defer allocator.free(z);
            if (c.mpz_init_set_str(out, z.ptr, 10) != 0) {
                return error.InvalidCertificate;
            }
        },
        .integer => |n| {
            c.mpz_init(out);
            if (n >= 0) {
                if (@as(u64, @intCast(n)) > std.math.maxInt(c_ulong)) return error.InvalidCertificate;
                c.mpz_set_ui(out, @as(c_ulong, @intCast(n)));
            } else {
                if (n < std.math.minInt(c_long)) return error.InvalidCertificate;
                c.mpz_set_si(out, @as(c_long, @intCast(n)));
            }
        },
        else => return error.InvalidCertificate,
    }
}

fn parseExponent(value: std.json.Value) !c_ulong {
    const n: u64 = switch (value) {
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        .integer => |i| blk: {
            if (i < 0) return error.InvalidCertificate;
            break :blk @as(u64, @intCast(i));
        },
        else => return error.InvalidCertificate,
    };

    if (n > std.math.maxInt(c_ulong)) return error.InvalidCertificate;
    return @as(c_ulong, @intCast(n));
}

fn parseRootArray(root: std.json.Value) !std.json.Array {
    return switch (root) {
        .array => |arr| arr,
        else => error.InvalidCertificate,
    };
}

fn parsePartArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |arr| arr,
        else => error.InvalidCertificate,
    };
}

fn mpzToOwnedDecimal(allocator: std.mem.Allocator, n: *const c.mpz_t) ![]u8 {
    const approx_digits = c.mpz_sizeinbase(n, 10);
    const buf = try allocator.alloc(u8, approx_digits + 3);
    errdefer allocator.free(buf);

    const p = c.mpz_get_str(@ptrCast(buf.ptr), 10, n);
    if (p == null) return error.OutOfMemory;

    const z: [*:0]u8 = @ptrCast(p);
    const s = std.mem.sliceTo(z, 0);
    const out = try allocator.dupe(u8, s);
    allocator.free(buf);
    return out;
}

const PartEntry = struct {
    part: std.json.Array,
    prime_key: []u8,
};

fn decimalLessThan(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len < b.len;
    return std.mem.order(u8, a, b) == .lt;
}

fn sortPartEntries(entries: []PartEntry) void {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        var j = i;
        while (j > 0 and decimalLessThan(entries[j].prime_key, entries[j - 1].prime_key)) : (j -= 1) {
            std.mem.swap(PartEntry, &entries[j], &entries[j - 1]);
        }
    }
}

fn partPrimeKey(allocator: std.mem.Allocator, part: std.json.Array) ![]u8 {
    if (part.items.len < 1) return error.InvalidCertificate;

    var prime: c.mpz_t = undefined;
    try parseMpz(allocator, part.items[0], &prime);
    defer c.mpz_clear(&prime);

    return mpzToOwnedDecimal(allocator, &prime);
}

fn verifyPart(
    allocator: std.mem.Allocator,
    part: std.json.Array,
    full_verify: bool,
    part_index: usize,
    part_count: usize,
) !void {
    if (part.items.len < 3) return fail("part too short", .{});

    if (full_verify) {
        std.debug.print("CHECK {d}/{d}\n", .{ part_index, part_count });
    }

    var prime: c.mpz_t = undefined;
    try parseMpz(allocator, part.items[0], &prime);
    defer c.mpz_clear(&prime);

    var witness: c.mpz_t = undefined;
    try parseMpz(allocator, part.items[1], &witness);
    defer c.mpz_clear(&witness);

    if (c.mpz_cmp_ui(&prime, 2) <= 0) return fail("prime must be > 2", .{});
    if (c.mpz_cmp_ui(&witness, 1) <= 0) return fail("witness must be > 1", .{});

    var gcd: c.mpz_t = undefined;
    c.mpz_init(&gcd);
    defer c.mpz_clear(&gcd);
    c.mpz_gcd(&gcd, &prime, &witness);
    if (c.mpz_cmp_ui(&gcd, 1) != 0) return fail("gcd(prime, witness) != 1", .{});

    var n_minus_one: c.mpz_t = undefined;
    mpzInitSetUi(&n_minus_one, 1);
    defer c.mpz_clear(&n_minus_one);

    var one: c.mpz_t = undefined;
    mpzInitSetUi(&one, 1);
    defer c.mpz_clear(&one);

    var idx: usize = 2;
    while (idx < part.items.len) : (idx += 1) {
        const factor_value = part.items[idx];

        var factor: c.mpz_t = undefined;
        var exp: c_ulong = 1;

        switch (factor_value) {
            .array => |arr| {
                if (arr.items.len != 2) return fail("factor pair must have 2 items", .{});
                try parseMpz(allocator, arr.items[0], &factor);
                exp = try parseExponent(arr.items[1]);
                if (exp <= 1) {
                    c.mpz_clear(&factor);
                    return fail("factor exponent must be > 1", .{});
                }
            },
            else => {
                try parseMpz(allocator, factor_value, &factor);
            },
        }
        defer c.mpz_clear(&factor);

        if (c.mpz_cmp_ui(&factor, 1) <= 0) return fail("factor must be > 1", .{});

        var factor_pow: c.mpz_t = undefined;
        c.mpz_init(&factor_pow);
        defer c.mpz_clear(&factor_pow);

        if (exp == 1) {
            c.mpz_set(&factor_pow, &factor);
        } else {
            c.mpz_pow_ui(&factor_pow, &factor, exp);
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

    if (full_verify) {
        const factor_count = part.items.len - 2;
        idx = 2;
        while (idx < part.items.len) : (idx += 1) {
            const factor_value = part.items[idx];

            const base_value = switch (factor_value) {
                .array => |arr| blk: {
                    if (arr.items.len != 2) return fail("factor pair must have 2 items", .{});
                    break :blk arr.items[0];
                },
                else => factor_value,
            };

            var factor: c.mpz_t = undefined;
            try parseMpz(allocator, base_value, &factor);
            defer c.mpz_clear(&factor);

            if (c.mpz_divisible_p(&n_minus_one, &factor) == 0) {
                return fail("factor does not divide prime-1", .{});
            }

            var q: c.mpz_t = undefined;
            c.mpz_init(&q);
            defer c.mpz_clear(&q);
            c.mpz_divexact(&q, &n_minus_one, &factor);

            var check: c.mpz_t = undefined;
            c.mpz_init(&check);
            defer c.mpz_clear(&check);
            c.mpz_powm(&check, &witness, &q, &prime);

            if (c.mpz_cmp(&check, &one) == 0) {
                return fail("witness^((prime-1)/factor) mod prime == 1", .{});
            }

            const factor_index = idx - 1;
            std.debug.print("  FACTOR {d}/{d}\n", .{ factor_index, factor_count });
        }
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    _ = args.next();

    var full_verify = false;
    var input_path: []const u8 = "PRIME.json";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verify")) {
            full_verify = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("usage: zig run src/verify_gmp.zig -lc -lgmp -- [--verify] [path-to-json]\n", .{});
            return;
        } else {
            input_path = arg;
        }
    }

    const json_bytes = try std.fs.cwd().readFileAlloc(gpa, input_path, std.math.maxInt(usize));
    defer gpa.free(json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{
        .parse_numbers = false,
    });
    defer parsed.deinit();

    const root = try parseRootArray(parsed.value);
    if (root.items.len == 0) return fail("empty certificate", .{});

    var seen_primes = std.StringHashMap(void).init(gpa);
    defer {
        var it = seen_primes.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen_primes.deinit();
    }

    var ordered_parts = std.array_list.Managed(PartEntry).init(gpa);
    defer {
        for (ordered_parts.items) |entry| gpa.free(entry.prime_key);
        ordered_parts.deinit();
    }

    var i: usize = 0;
    while (i < root.items.len) : (i += 1) {
        const part = try parsePartArray(root.items[i]);
        try ordered_parts.append(.{
            .part = part,
            .prime_key = try partPrimeKey(gpa, part),
        });
    }
    sortPartEntries(ordered_parts.items);

    i = 0;
    while (i < ordered_parts.items.len) : (i += 1) {
        const entry = ordered_parts.items[i];
        try verifyPart(gpa, entry.part, full_verify, i + 1, root.items.len);

        const key = try gpa.dupe(u8, entry.prime_key);
        errdefer gpa.free(key);
        const found = try seen_primes.getOrPut(key);
        if (found.found_existing) {
            gpa.free(key);
            return fail("duplicate part prime", .{});
        }
        found.key_ptr.* = key;
    }

    var two: c.mpz_t = undefined;
    mpzInitSetUi(&two, 2);
    defer c.mpz_clear(&two);

    i = 0;
    while (i < ordered_parts.items.len) : (i += 1) {
        const part = ordered_parts.items[i].part;

        var j: usize = 2;
        while (j < part.items.len) : (j += 1) {
            const factor_value = part.items[j];
            const factor_number = switch (factor_value) {
                .array => |arr| blk: {
                    if (arr.items.len != 2) return fail("factor pair must have 2 items", .{});
                    break :blk arr.items[0];
                },
                else => factor_value,
            };

            var factor: c.mpz_t = undefined;
            try parseMpz(gpa, factor_number, &factor);
            defer c.mpz_clear(&factor);

            if (c.mpz_cmp(&factor, &two) != 0) {
                const key = try mpzToOwnedDecimal(gpa, &factor);
                defer gpa.free(key);
                if (!seen_primes.contains(key)) {
                    return fail("missing certificate for factor", .{});
                }
            }
        }
    }

    std.debug.print("OK ({d} parts{s})\n", .{ root.items.len, if (full_verify) ", full verify" else "" });
}
