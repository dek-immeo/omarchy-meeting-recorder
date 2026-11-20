"""Install the verified ARM64 runtime and build its small C++ SDK adapter."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

package = "microsoft.cognitiveservices.speech"
version = "1.53.1"
sha256 = "c0b34b8f3d798a35bfdc022865625abf51820fa7024c95dd4b4aeb4ae4de9430"
url = f"https://api.nuget.org/v3-flatcontainer/{package}/{version}/{package}.{version}.nupkg"
contents = Path(sys.argv[1]).resolve()
frameworks = contents / "Frameworks"
runtime = "libMicrosoft.CognitiveServices.Speech.core.dylib"
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    archive = tmp / "speech.zip"
    with urllib.request.urlopen(url, timeout=90) as response, archive.open("wb") as out:
        shutil.copyfileobj(response, out)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != sha256:
        raise SystemExit("Microsoft Speech SDK checksum mismatch")
    with zipfile.ZipFile(archive) as sdk:
        for name in sdk.namelist():
            if name.startswith("build/native/include/"):
                sdk.extract(name, tmp)
        (frameworks / runtime).write_bytes(sdk.read(f"runtimes/osx-arm64/native/{runtime}"))
        (contents / "Resources/Microsoft-Speech-LICENSE.txt").write_bytes(sdk.read("LICENSE.txt"))
        (contents / "Resources/Microsoft-Speech-REDIST.txt").write_bytes(sdk.read("build/REDIST.txt"))
    headers = tmp / "build/native/include"
    bridge = frameworks / "libMeetingSpeech.dylib"
    subprocess.run(["xcrun", "clang++", "-arch", "arm64", "-mmacosx-version-min=13.0",
                    "-std=c++17", "-O2", "-dynamiclib", Path(__file__).with_name("bridge.cpp"),
                    "-I", headers / "c_api", "-I", headers / "cxx_api", frameworks / runtime,
                    "-Wl,-rpath,@loader_path", "-Wl,-install_name,@rpath/libMeetingSpeech.dylib",
                    "-o", bridge], check=True)
    for path in [frameworks / runtime, bridge]:
        subprocess.run(["codesign", "--force", "--sign", "-", path], check=True)
