"""Run with WORKER=/path/to/compiled/worker python test_worker_plan.py."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


WORKER = os.environ.get("WORKER")


@unittest.skipUnless(WORKER, "set WORKER to a compiled CPU worker")
class WorkerPlanTests(unittest.TestCase):
    def run_worker(self, plan, bases="3\n5\n7\n"):
        assert WORKER is not None
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "plan").write_text(plan, encoding="ascii")
            (path / "bases").write_text(bases, encoding="ascii")
            return subprocess.run([WORKER, "--plan", str(path / "plan"), "--bases", str(path / "bases")], cwd=path, text=True, capture_output=True)

    def test_plan_is_serial_and_ordered(self):
        result = self.run_worker("2\n3\n5\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([line for line in result.stdout.splitlines() if line.startswith("TEST ")], ["TEST index=0 q=2", "TEST index=1 q=3", "TEST index=2 q=5"])
        self.assertTrue(result.stdout.endswith("DONE\n"))

    def test_malformed_plan_is_rejected(self):
        result = self.run_worker("2\nnot-a-q\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("DONE", result.stdout)

    def test_invalid_bases_are_rejected(self):
        result = self.run_worker("2\n", "3\n5\n9\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
