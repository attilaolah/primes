"""Stable, shared candidate-plan format for the CPU and GPU search drivers."""
import hashlib
import ctypes
import os
from pathlib import Path
import sys
import time

MASK64 = (1 << 64) - 1
MAGIC = "PRIMES_CANDIDATE_PLAN_V1"


def _native_filter():
    """Load the Nix-installed helper, if one was made available to Python."""
    paths = []
    if configured := os.environ.get("PRIMES_CANDIDATE_FILTER_LIB"):
        paths.append(configured)
    suffixes = (".so", ".dylib", ".dll")
    paths.extend(str(Path(__file__).with_name("libcandidate_filter" + suffix)) for suffix in suffixes)
    for path in paths:
        try:
            library = ctypes.CDLL(path)
        except OSError:
            continue
        library.candidate_filter.argtypes = (
            ctypes.POINTER(ctypes.c_ubyte), ctypes.c_uint64,
            ctypes.POINTER(ctypes.c_uint64), ctypes.c_size_t, ctypes.c_char_p,
        )
        library.candidate_filter.restype = ctypes.c_int
        return library.candidate_filter
    return None


_CANDIDATE_FILTER = _native_filter()


def load_native_filter(path):
    """Load a helper selected by a Nix wrapper or by the orchestrator."""
    global _CANDIDATE_FILTER
    os.environ["PRIMES_CANDIDATE_FILTER_LIB"] = str(path)
    _CANDIDATE_FILTER = _native_filter()
    if _CANDIDATE_FILTER is None:
        raise OSError(f"could not load native candidate filter: {path}")


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
    started = time.monotonic()
    print(f"[*] Building candidate plan: sieve limit {sieve_limit}", flush=True)
    factor = 2 * bases[0] * bases[1] * bases[2]
    prime = _prime_sieve(sieve_limit)
    sieve_finished = time.monotonic()
    print(f"[*] Candidate-plan sieve constructed ({sieve_finished - started:.1f}s)", flush=True)
    sieve = [value for value in range(2, sieve_limit + 1) if prime[value]]
    # A prime r can divide factor*q+1 only when r does not divide factor, in
    # which case exactly one residue class of q modulo r is excluded.  Mark
    # that class directly rather than testing every (q, r) pair.
    eligible = bytearray(prime)
    if _CANDIDATE_FILTER is None:
        print("WARNING: native candidate filter unavailable; using slow Python residue filtering", file=sys.stderr, flush=True)
        _filter_python(eligible, sieve, factor, sieve_limit)
    else:
        divisors = (ctypes.c_uint64 * len(sieve))(*sieve)
        factor_decimal = str(factor).encode("ascii")
        status = _CANDIDATE_FILTER(
            (ctypes.c_ubyte * len(eligible)).from_buffer(eligible), sieve_limit, divisors, len(sieve), factor_decimal
        )
        if status == 1:
            raise RuntimeError("native candidate filter rejected a divisor")
        if status == 2:
            raise RuntimeError("native candidate filter rejected factor decimal input")
        if status:
            raise RuntimeError(f"native candidate filter failed with status {status}")
    filtering_finished = time.monotonic()
    print(f"[*] Candidate-plan residue filtering complete ({filtering_finished - sieve_finished:.1f}s)", flush=True)
    candidates = []
    progress_interval = 1_000_000
    for position, q in enumerate(sieve, 1):
        if eligible[q]:
            candidates.append(q)
        if position % progress_interval == 0:
            print(f"[*] Candidate collection: {position}/{len(sieve)} primes examined", flush=True)
    collection_finished = time.monotonic()
    print(f"[*] Candidate collection complete: {len(candidates)} candidates ({collection_finished - filtering_finished:.1f}s)", flush=True)
    result, state = list(candidates), seed
    for index in range(len(result) - 1, 0, -1):
        state, value = splitmix64(state)
        swap = value % (index + 1)
        result[index], result[swap] = result[swap], result[index]
    print(f"[*] Deterministic shuffle complete: {len(result)} candidates ({time.monotonic() - started:.1f}s)", flush=True)
    return result


def _filter_python(eligible, sieve, factor, sieve_limit):
    """Reference implementation retained for tests and explicit slow fallback."""
    for divisor in sieve:
        if factor % divisor:
            residue = (-pow(factor, -1, divisor)) % divisor
            count = ((sieve_limit - residue) // divisor) + 1
            eligible[residue : sieve_limit + 1 : divisor] = b"\x00" * count


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
    digest = plan_hash(bases, sieve_limit, seed, max_digits, candidates)
    body = _body(bases, sieve_limit, seed, max_digits, candidates)
    path.write_text(body.replace("--\n", f"sha256={digest}\n--\n"), encoding="ascii")
    return digest


def plan_hash(bases, sieve_limit, seed, max_digits, candidates):
    """Return the stable hash of a candidate plan's unsigned body."""
    return hashlib.sha256(_body(bases, sieve_limit, seed, max_digits, candidates).encode("ascii")).hexdigest()


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
