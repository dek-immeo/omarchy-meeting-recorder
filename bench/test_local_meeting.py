"""Regression tests with invented text. The private fixture is never opened."""
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import local_meeting as bench


class PrivateMeetingTest(unittest.TestCase):
    def test_words_and_speaker_permutations(self):
        self.assertEqual(bench.edits("a b c d".split(), "e b c a f".split()), 3)
        self.assertEqual(bench.edits([], ["ord"]), 1)
        reference = {"Speaker 1": ["æble", "pære"], "Speaker 2": ["blå"]}
        self.assertEqual(bench.speaker_edits(reference, {"A": ["blå"], "B": ["æble", "pære"]}), 0)
        self.assertEqual(bench.speaker_edits(reference, {"A": ["æble", "pære"]}), 1)

    def test_matching_transcript_does_not_approve_missing_summary(self):
        with tempfile.TemporaryDirectory() as tmp, redirect_stdout(io.StringIO()):
            root = Path(tmp)
            files = [root / name for name in ("audio.m4a", "reference.txt", "reference.md")]
            for path, data in zip(files, ("audio", "Speaker 1\nÆble.\n\nPære.\n", "### Frugt\n")):
                path.write_text(data)
            run = root / ".benchmark" / "run-unit"
            run.mkdir(parents=True)
            inputs = {key: bench.digest(p) for key, p in zip(("audio", "transcript", "summary"), files)}
            bench.write_json(run / "manifest.json", {"inputs": inputs})
            candidate = run / "candidate.md"
            candidate.write_text("**[00:00:00.000] Import · Taler 5**  \nÆBLE, pære!")
            with patch.object(bench, "RESULTS", run.parent):
                self.assertEqual(bench.compare(run, files, check=True, pin=True), 1)
                report = json.loads((run / "report.json").read_text())
                self.assertEqual(report["metrics"]["cpWER"], 0)
                self.assertEqual(report["regression"], "pass")
                self.assertEqual(report["reference_quality"], "pending")
                (run / "candidate-summary.md").write_text("Frugt.")
                self.assertEqual(bench.compare(run, files, check=True, pin=False), 1)
                reviewed = run / json.loads((run / "report.json").read_text())["review_file"]
                review = json.loads(reviewed.read_text())
                review["criteria"] = dict.fromkeys(review["criteria"], True)
                bench.write_json(reviewed, review)
                self.assertEqual(bench.compare(run, files, check=True, pin=False), 0)
                with candidate.open("a") as output:
                    output.write(" banan")
                self.assertEqual(bench.compare(run, files, check=True, pin=False), 1)
                report = json.loads((run / "report.json").read_text())
                self.assertEqual(report["regression"], "fail")
                self.assertEqual(report["reference_quality"], "pending")


if __name__ == "__main__":
    unittest.main()
