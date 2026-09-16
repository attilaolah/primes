#!/usr/bin/env python3
# Copyright (c) 2026
"""Run the CUDA candidate pre-sieve continuously and resume its output file."""

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from rich.progress import Progress

DEFAULT_Q_START = 1_000_000_001
UINT32_MAX = (1 << 32) - 1
UINT64_MAX = (1 << 64) - 1


def parse_args() -> argparse.Namespace:
    """Parse and validate the command line arguments.

    Returns:
        The parsed command line arguments.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--primes-file", required=True, type=Path)
    parser.add_argument("--batch-size", type=int, default=10_000_000)
    parser.add_argument("--sieve-limit", type=int, default=1_000_000_000)
    args = parser.parse_args()
    if not 0 < args.batch_size <= UINT32_MAX:
        parser.error("--batch-size must be between 1 and 4294967295")
    if args.sieve_limit < 2:
        parser.error("--sieve-limit must be at least 2")
    return args


def read_primes(path: Path) -> tuple[int, int, int]:
    """Read the first three integer lines from the primes file.

    Args:
        path: Text file whose first three lines are the base primes.

    Returns:
        The three base primes P1, P2 and P3.

    Raises:
        SystemExit: If the file is unreadable or the first three lines are not
            positive integers.
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        primes = tuple(int(line.strip()) for line in lines[:3])
    except (OSError, ValueError) as error:
        msg = f"could not read three integer primes from {path}: {error}"
        raise SystemExit(
            msg,
        ) from error
    if len(primes) != 3 or any(prime <= 0 for prime in primes):
        msg = f"{path} must begin with three positive integer primes"
        raise SystemExit(msg)
    return primes


def resume_q_start(output: Path) -> int:
    """Determine the next candidate value based on the last line of the file.

    Args:
        output: The candidates output file to resume from.

    Returns:
        The value of the last recorded candidate plus two, or the default
        starting value when the file is missing or empty.
    """
    if not output.exists() or output.stat().st_size == 0:
        return DEFAULT_Q_START
    with output.open("rb") as candidate_file:
        end = candidate_file.seek(0, os.SEEK_END)
        position = end
        while position:
            position -= 1
            candidate_file.seek(position)
            if candidate_file.read(1) != b"\n":
                break
        end_of_line = position + 1
        while position:
            position -= 1
            candidate_file.seek(position)
            if candidate_file.read(1) == b"\n":
                position += 1
                break
        candidate_file.seek(position)
        last_q = int(candidate_file.read(end_of_line - position))
    return last_q + 2


def limbs_for(value: int) -> list[int]:
    """Split a value into 32-bit little-endian limbs.

    Args:
        value: Integer value to be split into limbs.

    Returns:
        List of 32-bit limbs, with the least significant first.
    """
    limbs: list[int] = []
    while value:
        limbs.append(value & UINT32_MAX)
        value >>= 32
    return limbs or [0]


def run_batch(
    generate_input: Path,
    sieve: Path,
    limbs: list[int],
    q_start: int,
    batch_size: int,
    sieve_limit: int,
) -> tuple[int, bytes]:
    """Run one sieve batch and return the survivor count and flag bytes.

    Args:
        generate_input: Path to the pre-built input generator binary.
        sieve: Path to the pre-built CUDA sieve binary.
        limbs: Base value split into 32-bit little-endian limbs.
        q_start: First candidate value in the batch.
        batch_size: Number of candidates in the batch.
        sieve_limit: Prime limit used by the sieve.

    Returns:
        The number of surviving candidates and the raw flag bytes.

    Raises:
        RuntimeError: If the binary produces an unexpected number of bytes.
    """
    with tempfile.TemporaryDirectory(prefix="cuda-sieve-") as temporary_directory:
        workdir = Path(temporary_directory)
        limb_file = workdir / "base_limbs.txt"
        limb_file.write_text("\n".join(map(str, limbs)) + "\n", encoding="ascii")
        subprocess.run(
            [
                str(generate_input),
                str(len(limbs)),
                str(batch_size),
                str(q_start),
                str(sieve_limit),
                f"@{limb_file}",
            ],
            check=True,
            cwd=workdir,
        )
        environment = os.environ.copy()
        environment.setdefault("LD_LIBRARY_PATH", "/run/opengl-driver/lib")
        subprocess.run([str(sieve)], check=True, cwd=workdir, env=environment)
        output = (workdir / "sieve_output.bin").read_bytes()
    if len(output) != batch_size:
        msg = f"sieve produced {len(output)} bytes, expected {batch_size}"
        raise RuntimeError(msg)
    return sum(flag == 0 for flag in output), output


def append_survivors(output_path: Path, flags: bytes, q_start: int) -> int:
    """Append surviving candidate values to the output file.

    Args:
        output_path: Candidate file to append to.
        flags: Raw "is bad" flag bytes from the sieve.
        q_start: First candidate value in the batch.

    Returns:
        The number of survivors that were appended.
    """
    survivors = 0
    with output_path.open("a", encoding="ascii") as candidate_file:
        for offset, is_bad in enumerate(flags):
            if not is_bad:
                candidate_file.write(f"{q_start + 2 * offset}\n")
                survivors += 1
    return survivors


def main() -> None:
    """Run the CUDA pre-sieve indefinitely, resuming from saved candidates.

    Raises:
        RuntimeError: If the candidate range would exceed 64 bits.
    """
    sys.set_int_max_str_digits(0)
    args = parse_args()
    primes = read_primes(args.primes_file)
    fingerprint = hashlib.sha256(
        "_".join(map(str, primes)).encode("ascii"),
    ).hexdigest()[:8]
    output_path = Path.cwd() / f"candidates_{fingerprint}.txt"
    q_start = resume_q_start(output_path)
    base_limbs = limbs_for(primes[0] * primes[1] * primes[2] * 2)
    binary_directory = Path(__file__).resolve().parent
    generate_input = binary_directory / "generate_input"
    sieve = binary_directory / "sieve"
    total_survivors = 0

    try:
        with Progress() as progress:
            task = progress.add_task(
                "CUDA pre-sieve",
                q_start=q_start,
                sieve_limit=args.sieve_limit,
                survivors=total_survivors,
            )
            while True:
                if q_start + 2 * (args.batch_size - 1) > UINT64_MAX:
                    msg = "candidate range exceeds uint64_t"
                    raise RuntimeError(msg)
                _, flags = run_batch(
                    generate_input,
                    sieve,
                    base_limbs,
                    q_start,
                    args.batch_size,
                    args.sieve_limit,
                )
                total_survivors += append_survivors(output_path, flags, q_start)
                q_start += 2 * args.batch_size
                progress.update(
                    task,
                    description=(
                        f"CUDA pre-sieve q={q_start:,} limit={args.sieve_limit:,} "
                        f"survivors={total_survivors:,}"
                    ),
                )
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
