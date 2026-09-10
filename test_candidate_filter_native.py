"""Integration tests for the optional GMP-backed candidate filter."""
import ctypes
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
        native_filter = candidate_plan._CANDIDATE_FILTER
        if native_filter is None:
            self.fail("native candidate filter unavailable")
        status = native_filter(
            (ctypes.c_ubyte * len(eligible)).from_buffer(eligible),
            2,
            divisors,
            1,
            b"not-a-decimal-factor",
        )
        self.assertEqual(status, 2)
