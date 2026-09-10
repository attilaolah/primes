import unittest

from candidate_plan import candidate_plan, read_plan, primes_to


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
    def test_optimized_filter_matches_brute_force(self):
        for bases in ((3, 5, 7), (5, 11, 13), (3, 3, 5)):
            for limit in (2, 10, 50, 101):
                for seed in (0, 1, 12):
                    self.assertEqual(candidate_plan(bases, limit, seed), brute_force_plan(bases, limit, seed))

    def test_deterministic_output(self):
        self.assertEqual(candidate_plan((3, 5, 7), 101, 42), candidate_plan((3, 5, 7), 101, 42))

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
