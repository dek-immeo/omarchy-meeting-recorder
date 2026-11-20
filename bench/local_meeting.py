"""Offline macOS benchmark using the installed recorder and private local references."""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
from functools import lru_cache
from hashlib import sha256
from itertools import zip_longest
import json
import os
from pathlib import Path
import re
from subprocess import DEVNULL, run
import sys
from tempfile import TemporaryDirectory, mkdtemp
import unicodedata

ROOT = Path(__file__).resolve().parents[1] / "localtestdata"
RESULTS = ROOT / ".benchmark"
APP = Path("/Applications/Meeting Recorder.app/Contents")
MODELS = Path.home() / "Library/Application Support/Meeting Recorder/Models"
OFFLINE = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)"]
SPEAKER = re.compile(r"(?:Speaker|Taler)\s+\d+", re.I)
TURN = re.compile(r"\*\*\[\d+:\d{2}:\d{2}\.\d{3}\] Import · (Taler \d+|Ukendt taler)\*\*")


def inputs():
    files = []
    for suffix in (".m4a", ".txt", ".md"):
        found = [p for p in ROOT.rglob("*") if p.is_file() and p.suffix.lower() == suffix
                 and not any(part.startswith(".") for part in p.relative_to(ROOT).parts)]
        if len(found) != 1:
            raise ValueError(f"Expected one private {suffix} reference/input, found {len(found)}")
        files.append(found[0])
    if len({p.parent for p in files}) != 1:
        raise ValueError("Keep the three input files in the same meeting folder")
    return files


def digest(path):
    result = sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def transcribe(audio, out):
    helper = APP / "Helpers/meeting-transcriber"
    env = dict(os.environ, ORT_DYLIB_PATH=str(APP / "Frameworks/libonnxruntime.dylib"))
    with TemporaryDirectory(dir=out) as tmp:
        work = Path(tmp)
        with (out / "worker.log").open("w") as log:
            run(OFFLINE + ["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16", audio,
                           work / "Import.wav"], check=True, stdout=log, stderr=log)
            run(OFFLINE + [helper, work, MODELS], check=True, env=env,
                stdin=DEVNULL, stdout=log, stderr=log)
        (work / "Transskription.md").rename(out / "candidate.md")


def read_words(path, header, native=False):
    words, speakers = [], defaultdict(list)
    speaker = None
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        match = header.fullmatch(line.strip())
        if match:
            speaker = match[1] if native else match[0]
        elif line.strip():
            if speaker is None:
                if native:
                    continue  # Markdown title and model metadata before the first turn
                raise ValueError("Unrecognised reference speaker format")
            tokens = re.findall(r"[^\W_]+", unicodedata.normalize("NFC", line).casefold())
            words.extend(tokens)
            speakers[speaker].extend(tokens)
    return words, speakers


def edits(reference, candidate):
    """Exact unit-cost Levenshtein distance, using Myers' bit-vector algorithm."""
    if not reference:
        return len(candidate)
    masks = {}
    for i, word in enumerate(reference):
        masks[word] = masks.get(word, 0) | (1 << i)
    pos, neg, score = -1, 0, len(reference)
    top = 1 << (score - 1)
    for word in candidate:
        eq = masks.get(word, 0)
        x = eq | neg
        diff = (((eq & pos) + pos) ^ pos) | eq
        up = neg | ~(diff | pos)
        down = pos & diff
        score += bool(up & top) - bool(down & top)
        up = (up << 1) | 1
        pos, neg = (down << 1) | ~(x | up), up & x
    return score


def speaker_edits(ref, hyp):
    """Minimum cost across assignments, pairing excess speakers with empty text."""
    pairs = list(zip_longest(ref.values(), hyp.values(), fillvalue=[]))
    costs = [[edits(a, b) for _, b in pairs] for a, _ in pairs]

    @lru_cache(None)
    def assign(row, used):
        if row == len(costs):
            return 0
        return min(cost + assign(row + 1, used | 1 << col)
                   for col, cost in enumerate(costs[row]) if not used & 1 << col)
    return assign(0, 0)


def write_json(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def manifest(files):
    return {
        "inputs": {key: digest(path) for key, path in zip(("audio", "transcript", "summary"), files)},
        "worker": digest(APP / "Helpers/meeting-transcriber"),
        "created_utc": datetime.now(timezone.utc).isoformat(),
    }


def compare(out, files, check, pin):
    _, ref_text, ref_summary = files
    candidate = out / "candidate.md"
    recorded = json.loads((out / "manifest.json").read_text())
    if recorded["inputs"] != {k: digest(p) for k, p in zip(("audio", "transcript", "summary"), files)}:
        raise ValueError("Inputs changed since transcription; start a new run")
    ref, ref_people = read_words(ref_text, SPEAKER)
    hyp, hyp_people = read_words(candidate, TURN, native=True)
    if not ref:
        raise ValueError("Empty reference transcript")
    counts = {"word_edits": edits(ref, hyp), "speaker_word_edits": speaker_edits(ref_people, hyp_people)}
    metrics = dict(reference_words=len(ref), candidate_words=len(hyp), reference_labels=len(ref_people),
                   candidate_labels=len(hyp_people), **counts)
    metrics["WER"] = counts["word_edits"] / len(ref)
    metrics["cpWER"] = counts["speaker_word_edits"] / len(ref)
    baseline_path = RESULTS / "regression-baseline.json"
    if pin:
        if baseline_path.exists() or not hyp:
            raise ValueError("Pin requires a nonempty candidate and no existing regression baseline")
        write_json(baseline_path, {"inputs": recorded["inputs"], "metrics_version": 1, **counts})
    regression = "missing_baseline"
    if baseline_path.exists():
        baseline = json.loads(baseline_path.read_text())
        if baseline["inputs"] != recorded["inputs"] or baseline["metrics_version"] != 1:
            raise ValueError("Regression baseline belongs to different inputs or scoring version")
        regression = "pass" if all(counts[k] <= baseline[k] for k in counts) else "fail"

    # Review paraphrases against the audio and reference, locally and per topic.
    summary = out / "candidate-summary.md"
    headings = re.findall(r"^#{2,6}\s+(.+)$", ref_summary.read_text(encoding="utf-8-sig"), re.M)
    criteria = ["Transcript fidelity, material names and numbers", "Speaker attribution",
                "Summary factual accuracy, no unsupported claims",
                "Summary decisions, actions, owners and deadlines where stated"]
    criteria.extend("Summary covers: " + h.strip() for h in headings)
    artifacts = {"transcript": digest(candidate), "summary": digest(summary) if summary.is_file() else None}
    version = sha256(json.dumps(artifacts, sort_keys=True).encode()).hexdigest()[:16]
    review_path = out / f"review-{version}.json"
    if not review_path.exists():
        write_json(review_path, {"candidate_sha256": artifacts, "criteria": dict.fromkeys(criteria)})
    review = json.loads(review_path.read_text())
    values = review["criteria"]
    current = review.get("candidate_sha256") == artifacts
    complete = (bool(hyp) and summary.is_file() and bool(summary.read_text(encoding="utf-8-sig").strip())
                and current and all(values.get(c) is True for c in criteria))
    quality = "pass" if complete else "pending"
    if current and any(values.get(c) is False for c in criteria):
        quality = "fail"
    report = {"metrics": metrics, "regression": regression, "reference_quality": quality,
              "candidate_summary_present": summary.is_file(), "review_matches_candidate": current,
              "review_file": review_path.name}
    write_json(out / "report.json", report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return int(check and (regression != "pass" or quality != "pass"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rescore", metavar="RUN", help="use a completed run directory name")
    parser.add_argument("--pin-regression", action="store_true", help="save the first regression comparator")
    parser.add_argument("--summarize", action="store_true", help="generate the local app summary for this run")
    parser.add_argument("--check", action="store_true", help="require regression and reference-quality approval")
    args = parser.parse_args()
    os.umask(0o077)
    files = inputs()
    RESULTS.mkdir(mode=0o700, exist_ok=True)
    if args.rescore:
        if not re.fullmatch(r"run-[\w-]+", args.rescore):
            parser.error("Expected a run directory name")
        out = RESULTS / args.rescore
    else:
        out = Path(mkdtemp(prefix="run-", dir=RESULTS))
        write_json(out / "manifest.json", manifest(files))
        print(f"Running offline in {out.relative_to(ROOT.parent)}", flush=True)
        transcribe(files[0], out)
    if args.summarize:
        run([APP / "Helpers/meeting-summary", out / "candidate.md", out / "candidate-summary.md"], check=True)
    return compare(out, files, args.check, args.pin_regression)


if __name__ == "__main__":
    sys.exit(main())
