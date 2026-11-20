# Bench

A small test suite for the transcription and the speakers: it runs the app's own command line over a set of recordings and scores the result. Use it to check a change, or to compare another speech or speaker model against what the app does now.

```bash
cargo build --release
bench/run.py                          # the six cases in fixtures/, about two minutes
bench/run.py --ami                    # plus the first 5 minutes of a real AMI meeting (downloads about 170 MB once)
bench/run.py --ami --ami-minutes 0    # the whole 17 minute meeting
bench/run.py --ami --check            # fail when a case scores below thresholds.json, as CI does
bench/run.py --bin /usr/bin/omarchy-meeting-recorder --json old.json    # any other build
bench/run.py --case room music        # only some cases
```

Only Python's standard library is needed, plus ffmpeg for the AMI download. The speech and speaker models are the app's own, downloaded on first use as usual.

## The cases

| Case | What it tests |
|---|---|
| `call` | You on a headset, three people on the other side who interrupt each other and say "yeah" in between |
| `call-speakers` | The same call through speakers: the other side leaks into your mic, 40 ms late |
| `room` | Two people share your mic, two people on the other side |
| `music` | The other side talks with music playing in the background |
| `import` | The `call` as one mixed file, as if dropped on the app |
| `silence` | Twenty seconds of room noise: the transcript must be empty |
| `noisy-mic` | `call` with the mic's noise floor at about −32 dBFS under speech peaking near −17 dBFS, like a cheap or onboard mic (#27) |
| `silent-mic` | `call` with nobody speaking on your side: the mic only hears room noise at about −38 dBFS, and no line may be yours (`invented` stays 0) |
| `ami-ES2004a-import` | A real four-person meeting as one mixed file (with `--ami`, the first 5 minutes by default) |
| `ami-ES2004a-call` | The same meeting as a call: one person's headset is your mic, the other three are the computer audio |

Each case in `fixtures/` has its audio as Opus (like the app's own recordings) and a `truth.json` with every line: who said it, on which side, when, and the words.

## The columns

- **found**: words of the script that are in the transcript, near the right moment
- **side**: of those, on the right side of the call (you or the other side)
- **person**: of those, with the right person (labels are matched to people one to one)
- **leaked**: lines of yours that are really the other side coming through your speakers
- **lines**: lines in the transcript, only for `silence`
- **speakers**: voices told apart, out of the voices in the case
- **speaker error**: share of speech that `diarize` gives to the wrong speaker (imports only)
- **seconds**: how long the transcription took

For AMI there is no script, so side and person are measured by who was speaking during each line, weighted by its words.

## In CI

Every pull request and every push to main runs the bench with `--ami --model small.en --check` on GitHub Actions (`.github/workflows/bench.yml`), and fails when a case drops below `thresholds.json`. CI uses the `small.en` whisper model: with the app's default model a run takes over half an hour on GitHub's four cores, and the bench is mostly about who said what, which does not depend on the model. The thresholds sit a few points under the scores with `small.en`, so a different CPU does not fail a run by chance. The scores go into the run's summary, and "Bench comment" posts them on the pull request, also on pull requests from forks. A change that makes the app better can raise the thresholds in the same pull request.

## Making new cases

The fixtures are generated from the scripts in `scripts/`, meetings of a small team working on Omarchy, with [piper](https://github.com/OHF-Voice/piper1-gpl) voices that are in the public domain or CC0 (Joe, John, Kristin, Norman and Cori from [piper-voices](https://huggingface.co/rhasspy/piper-voices)):

```bash
bench/generate.py ~/path/to/piper-voices
```

A script line is `speaker|gap|text`, where the gap is the seconds after the previous line ends; a negative gap makes them talk at the same time. The generated files are committed, so running the bench does not need piper.

## Licenses

The generated fixtures are CC0. AMI is © the AMI Consortium, [CC BY 4.0](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml); its speaker annotations come from [pyannote/AMI-diarization-setup](https://github.com/pyannote/AMI-diarization-setup). Neither is stored in this repository: `--ami` downloads them to `bench/.cache/`.

## Private meeting benchmark on macOS

Keep one meeting's original M4A, plain-text speaker transcript and Markdown summary together under `localtestdata/`. The local benchmark uses the installed Mac app's transcription helper and cached models. It converts the audio to PCM using Apple's decoder at the original sample rate and channel count. Both the decoder and helper run with network access denied. Models must already be present. Each run writes to a fresh private directory under `localtestdata/.benchmark/`. Git ignores this directory and all source material under `localtestdata/`. The public CI benchmark uses its own fixtures.

```sh
python3 bench/local_meeting.py
python3 bench/local_meeting.py --rescore run-EXAMPLE --check
```

The report measures the word error rate (WER) against the supplied reference, after Unicode normalization, case folding and splitting on punctuation. WER counts substitutions, deletions and insertions, divided by the reference word count. Speaker-attributed WER (cpWER) groups words by speaker and picks the best one-to-one pairing of speaker labels, counting unmatched speakers' words as errors. Lower is better for both. Reference speaker headings may use `Speaker 1` or `Taler 1`. Unlabelled continuation paragraphs belong to the preceding speaker. The external transcript serves as a comparison point. Where the two transcripts disagree, listen to the audio to determine which rendering is faithful.

Two independent conditions determine the result of `--check`.

1. **Regression.** Use `python3 bench/local_meeting.py --rescore run-EXAMPLE --pin-regression` once to save the first working run's edit counts. Future runs on the same three input files must keep both counts at or below those values. The baseline is local. Rescoring uses the saved transcript and does not rerun the models.
2. **Reference quality.** Compare the candidate transcript with the reference and audio, including material names, numbers and speaker attribution. When a local summary is available, put the candidate output in the run directory as `candidate-summary.md` and rescore. Open the review file named in `report.json`. It includes one item per reference topic, plus factual accuracy, decisions and follow-up items. Mark each item `true` only when the candidate meets or exceeds the reference, or `false` for a material shortfall. Leave unresolved items as `null`. Review decisions are tied to the exact candidate files. Rescore with `--check` after review.

A missing summary or pending review leaves the reference-quality check open. A normal run still reports transcript metrics. Keep generated transcripts, summaries, reviews and worker logs in the ignored directory.

For the private Mac case, `python3 bench/local_meeting.py --rescore run-EXAMPLE --summarize` uses the installed app's on-device summary engine and writes the candidate summary beside the generated transcript. Run `python3 bench/local_review.py run-EXAMPLE` for a local Danish qualitative report. It selects aligned passages from eight parts of the meeting, evaluates them with the offline model, and retains the source excerpts and playback times for listening. Model observations remain separate from the human reference-quality check.
