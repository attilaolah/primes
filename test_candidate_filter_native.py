"""Integration tests for the optional GMP-backed candidate filter."""
import ctypes
import contextlib
import io
import json
import os
import pty
import select
import subprocess
import sys
import unittest

import candidate_plan


@unittest.skipUnless(candidate_plan._CANDIDATE_FILTER, "native candidate filter unavailable")
class NativeCandidateFilterTests(unittest.TestCase):
    def test_matches_python_reference_and_plan_hash(self):
        bases = (3, 5, 7)
        native = candidate_plan.candidate_plan(bases, 101, 42)
        saved = candidate_plan._CANDIDATE_FILTER
        try:
            candidate_plan._CANDIDATE_FILTER = None
            reference = candidate_plan.candidate_plan(bases, 101, 42)
        finally:
            candidate_plan._CANDIDATE_FILTER = saved
        self.assertEqual(native, reference)
        self.assertEqual(
            candidate_plan.plan_hash(bases, 101, 42, None, native),
            candidate_plan.plan_hash(bases, 101, 42, None, reference),
        )

    def test_rejects_unparseable_factor_decimal(self):
        eligible = bytearray(b"\x01" * 3)
        divisors = (ctypes.c_uint64 * 1)(2)
        library = candidate_plan._CANDIDATE_FILTER
        if library is None:
            self.fail("native candidate filter unavailable")
        status = library.candidate_filter(
            (ctypes.c_ubyte * len(eligible)).from_buffer(eligible),
            2,
            divisors,
            1,
            b"not-a-decimal-factor",
        )
        self.assertEqual(status, 2)

    def test_omp_thread_counts_have_identical_candidates(self):
        """Run separate processes so OpenMP reads each OMP_NUM_THREADS value."""
        script = """
import contextlib, io, json
import candidate_plan
with contextlib.redirect_stdout(io.StringIO()):
    candidates = candidate_plan.candidate_plan((3, 5, 7), 10_000, 42)
print(json.dumps(candidates))
"""
        outputs = []
        for threads in (1, 2):
            environment = os.environ | {"OMP_NUM_THREADS": str(threads)}
            result = subprocess.run(
                [sys.executable, "-c", script],
                check=True,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertNotIn("\r", result.stderr)
            outputs.append(json.loads(result.stdout))
        self.assertEqual(outputs[0], outputs[1])

    def test_progress_uses_carriage_return_on_an_interactive_stderr(self):
        script = """
import contextlib, io
import candidate_plan
with contextlib.redirect_stdout(io.StringIO()):
    candidate_plan.candidate_plan((3, 5, 7), 10_000, 42)
"""
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen(
                [sys.executable, "-c", script],
                stderr=slave,
                stdout=subprocess.DEVNULL,
                env=os.environ,
            )
        finally:
            os.close(slave)
        output = bytearray()
        while process.poll() is None:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    output.extend(os.read(master, 4096))
                except OSError:
                    break
        process.wait()
        while True:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        os.close(master)
        self.assertEqual(process.returncode, 0)
        progress = b"completed divisor-prime work"
        self.assertIn(progress, output)
        self.assertTrue(output.endswith(b"\n"))
