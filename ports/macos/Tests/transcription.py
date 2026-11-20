"""Exercise the packaged worker with the room fixture (two voices per source)."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

worker, cache = map(Path, sys.argv[1:])
fixtures = Path(__file__).resolve().parents[3] / "bench/fixtures/room"
with tempfile.TemporaryDirectory() as tmp:
    meeting = Path(tmp)
    for src, dest, rate, channels in [
        ("mic", "Mikrofon", "44100", "1"),
        ("computer", "Systemlyd", "48000", "2"),
    ]:
        subprocess.run([os.getenv("FFMPEG", "ffmpeg"), "-v", "error", "-i", fixtures / f"{src}.ogg",
                        "-ar", rate, "-ac", channels, "-c:a", "pcm_s16le", meeting / f"{dest}.wav"], check=True)
    subprocess.run([worker.resolve(), meeting, cache.resolve()], check=True)
    text = (meeting / "Transskription.md").read_text()
    turns = re.findall(r"\*\*\[(\d\d:\d\d:\d\d)\] (Mikrofon|Systemlyd) · Taler (\d+)\*\*  \n([^\n]+)", text)
    assert [t[0] for t in turns] == sorted(t[0] for t in turns), text
    for track in ["Mikrofon", "Systemlyd"]:
        speakers = {t[2] for t in turns if t[1] == track and len(t[3].split()) >= 4}
        assert len(speakers) >= 2, text
    assert "office" in text.lower() and "theme" in text.lower(), text
    print(text, flush=True)
