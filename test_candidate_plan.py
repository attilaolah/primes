import hashlib
import io
import unittest

import candidate_plan as plans
from candidate_plan import candidate_plan, plan_hash, read_plan, primes_to


def brute_force_plan(bases, sieve_limit, seed):
    sieve = primes_to(sieve_limit)
    factor = 2 * bases[0] * bases[1] * bases[2]
    candidates = [q for q in sieve if all((factor * q + 1) % divisor for divisor in sieve)]
    # Use the production shuffle with an otherwise independently-derived
    # candidate stream; its ordering is part of the plan format.
    from candidate_plan import splitmix64

    result, state = list(candidates), seed
    for index in range(len(result) - 1, 0, -1):
        state, value = splitmix64(state)
        swap = value % (index + 1)
        result[index], result[swap] = result[swap], result[index]
    return result


class CandidatePlanTests(unittest.TestCase):
    def test_candidate_collection_progress_reuses_one_line_and_terminates(self):
        class InteractiveStream(io.StringIO):
            def isatty(self):
                return True

        stream = InteractiveStream()
        previous_interval = plans.COLLECTION_PROGRESS_INTERVAL
        plans.COLLECTION_PROGRESS_INTERVAL = 2
        try:
            self.assertEqual(plans._collect_candidates([2, 3, 5], bytearray(b"\x00\x00\x01\x00\x01\x00"), 5, stream), [2])
        finally:
            plans.COLLECTION_PROGRESS_INTERVAL = previous_interval
        self.assertEqual(stream.getvalue(), "\r[*] Candidate collection: 2/5 primes examined\r[*] Candidate collection: 5/5 primes examined\n")

    def test_optimized_filter_matches_brute_force(self):
        for bases in ((3, 5, 7), (5, 11, 13), (3, 3, 5)):
            for limit in (2, 10, 50, 101):
                for seed in (0, 1, 12):
                    self.assertEqual(candidate_plan(bases, limit, seed), brute_force_plan(bases, limit, seed))

    def test_deterministic_output(self):
        self.assertEqual(candidate_plan((3, 5, 7), 101, 42), candidate_plan((3, 5, 7), 101, 42))

    def test_native_filter_matches_reference_with_large_and_shared_factors(self):
        library = plans._CANDIDATE_FILTER
        if library is None:
            self.skipTest("native candidate filter is not installed")
        for bases in ((3, 5, 7), (3, 3, 5), ((1 << 127) - 1, 3, 5)):
            for limit in (2, 17, 101, 257):
                prime = plans._prime_sieve(limit)
                sieve = primes_to(limit)
                factor = 2 * bases[0] * bases[1] * bases[2]
                expected = bytearray(prime)
                plans._filter_python(expected, sieve, factor, limit)
                output = plans.ctypes.POINTER(plans.ctypes.c_uint64)()
                output_count = plans.ctypes.c_size_t()
                self.assertEqual(
                    library.candidate_filter_from_sieve(
                        (plans.ctypes.c_ubyte * len(prime)).from_buffer(prime),
                        limit,
                        str(factor).encode("ascii"),
                        plans.ctypes.byref(output),
                        plans.ctypes.byref(output_count),
                    ),
                    0,
                )
                try:
                    self.assertEqual([output[index] for index in range(output_count.value)],
                                     [q for q in sieve if expected[q]])
                finally:
                    library.candidate_filter_free(output)

    def test_native_plan_hash_and_order_match_reference(self):
        native = plans._CANDIDATE_FILTER
        if native is None:
            self.skipTest("native candidate filter is not installed")
        bases, limit, seed = ((1 << 127) - 1, 3, 5), 257, 12
        native_plan = candidate_plan(bases, limit, seed)
        saved = plans._CANDIDATE_FILTER
        plans._CANDIDATE_FILTER = None
        try:
            reference_plan = candidate_plan(bases, limit, seed)
        finally:
            plans._CANDIDATE_FILTER = saved
        self.assertEqual(native_plan, reference_plan)
        self.assertEqual(plan_hash(bases, limit, seed, None, native_plan), plan_hash(bases, limit, seed, None, reference_plan))

    def test_malformed_plan_is_rejected(self):
        from pathlib import Path
        import tempfile

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan"
            path.write_text("not a plan\n", encoding="ascii")
            with self.assertRaises(ValueError):
                read_plan(path)


if __name__ == "__main__":
    unittest.main()
