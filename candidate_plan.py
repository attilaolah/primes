"""Stable, shared candidate-plan format for the CPU and GPU search drivers."""
import hashlib

MASK64 = (1 << 64) - 1
MAGIC = "PRIMES_CANDIDATE_PLAN_V1"


def primes_to(limit):
    if limit < 2:
        return []
    sieve = _prime_sieve(limit)
    return [value for value in range(2, limit + 1) if sieve[value]]


def _prime_sieve(limit):
    """Return a byte-per-integer primality table through *limit*."""
    sieve = bytearray(b"\x01") * (limit + 1)
    sieve[:2] = b"\x00\x00"
    for value in range(2, int(limit**0.5) + 1):
        if sieve[value]:
            sieve[value * value : limit + 1 : value] = b"\x00" * (((limit - value * value) // value) + 1)
    return sieve


def splitmix64(state):
    state = (state + 0x9E3779B97F4A7C15) & MASK64
    value = state
    value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
    value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & MASK64
    return state, value ^ (value >> 31)


def candidate_plan(bases, sieve_limit, seed):
    factor = 2 * bases[0] * bases[1] * bases[2]
    prime = _prime_sieve(sieve_limit)
    sieve = [value for value in range(2, sieve_limit + 1) if prime[value]]
    # A prime r can divide factor*q+1 only when r does not divide factor, in
    # which case exactly one residue class of q modulo r is excluded.  Mark
    # that class directly rather than testing every (q, r) pair.
    eligible = bytearray(prime)
    for divisor in sieve:
        if factor % divisor:
            residue = (-pow(factor, -1, divisor)) % divisor
            count = ((sieve_limit - residue) // divisor) + 1
            eligible[residue : sieve_limit + 1 : divisor] = b"\x00" * count
    candidates = [q for q in sieve if eligible[q]]
    result, state = list(candidates), seed
    for index in range(len(result) - 1, 0, -1):
        state, value = splitmix64(state)
        swap = value % (index + 1)
        result[index], result[swap] = result[swap], result[index]
    return result


def _body(bases, sieve_limit, seed, max_digits, candidates):
    return "\n".join((
        MAGIC,
        f"seed={seed}",
        f"sieve_limit={sieve_limit}",
        f"max_digits={'' if max_digits is None else max_digits}",
        "bases=" + ",".join(map(str, bases)),
        f"count={len(candidates)}",
        "--",
        *map(str, candidates),
        "",
    ))


def write_plan(path, bases, sieve_limit, seed, max_digits, candidates):
    body = _body(bases, sieve_limit, seed, max_digits, candidates)
    digest = hashlib.sha256(body.encode("ascii")).hexdigest()
    path.write_text(body.replace("--\n", f"sha256={digest}\n--\n"), encoding="ascii")
    return digest


def read_plan(path):
    lines = path.read_text(encoding="ascii").splitlines()
    if len(lines) < 8 or lines[0] != MAGIC or lines[7] != "--":
        raise ValueError("invalid candidate plan header")
    fields = {}
    for line in lines[1:7]:
        if "=" not in line:
            raise ValueError("invalid candidate plan metadata")
        key, value = line.split("=", 1)
        fields[key] = value
    if set(fields) != {"seed", "sieve_limit", "max_digits", "bases", "count", "sha256"}:
        raise ValueError("invalid candidate plan metadata")
    try:
        seed = int(fields["seed"])
        sieve_limit = int(fields["sieve_limit"])
        max_digits = None if fields["max_digits"] == "" else int(fields["max_digits"])
        bases = tuple(int(value) for value in fields["bases"].split(","))
        candidates = [int(value) for value in lines[8:]]
        count = int(fields["count"])
    except ValueError as error:
        raise ValueError("invalid candidate plan value") from error
    if not 0 <= seed <= MASK64 or sieve_limit <= 0 or max_digits is not None and max_digits <= 0 or len(bases) != 3 or any(value <= 1 for value in bases) or count != len(candidates) or any(value <= 1 for value in candidates):
        raise ValueError("invalid candidate plan value")
    body = _body(bases, sieve_limit, seed, max_digits, candidates)
    if hashlib.sha256(body.encode("ascii")).hexdigest() != fields["sha256"]:
        raise ValueError("candidate plan hash mismatch")
    if candidates != candidate_plan(bases, sieve_limit, seed):
        raise ValueError("candidate plan is not reproducible from metadata")
    return {"bases": bases, "sieve_limit": sieve_limit, "seed": seed, "max_digits": max_digits, "candidates": candidates, "hash": fields["sha256"]}
