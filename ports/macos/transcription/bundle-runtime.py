"""Bundle the standalone arm64 ORT library and notices from Microsoft's Ventura-compatible wheel."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import shutil
import sys
import urllib.request
import zipfile

contents = Path(sys.argv[1])
release = "1.23.2"
filename = f"onnxruntime-{release}-cp313-cp313-macosx_13_0_arm64.whl"
expected = "2ff531ad8496281b4297f32b83b01cdd719617e2351ffe0dba5684fb283afa1f"
with urllib.request.urlopen(f"https://pypi.org/pypi/onnxruntime/{release}/json", timeout=60) as response:
    asset = next(f for f in json.load(response)["urls"] if f["filename"] == filename)
with urllib.request.urlopen(asset["url"], timeout=120) as response:
    data = response.read()
if hashlib.sha256(data).hexdigest() != expected:
    raise ValueError("ONNX Runtime wheel checksum mismatch")
with zipfile.ZipFile(io.BytesIO(data)) as wheel:
    for source, target in [
        (f"onnxruntime/capi/libonnxruntime.{release}.dylib", "Frameworks/libonnxruntime.dylib"),
        ("onnxruntime/LICENSE", "Resources/ONNXRuntime-LICENSE"),
        ("onnxruntime/ThirdPartyNotices.txt", "Resources/ONNXRuntime-ThirdPartyNotices.txt"),
    ]:
        (contents / target).write_bytes(wheel.read(source))

metadata = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--locked", "--format-version", "1", "--filter-platform", "aarch64-apple-darwin",
     "--manifest-path", str(Path(__file__).with_name("Cargo.toml"))]
))
for package in metadata["packages"]:
    if package["name"] == "transcribe-cpp-sys":
        root = Path(package["manifest_path"]).parent
        for name in ["LICENSE", "THIRD-PARTY-LICENSES.md", "ggml/LICENSE"]:
            shutil.copyfile(root / name, contents / "Resources" / ("transcribe-cpp-" + name.replace("/", "-")))
