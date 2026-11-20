"""Drive the shipped Microsoft SDK against a loopback Speech protocol fixture."""
import asyncio
import json
from pathlib import Path
import re
import sys
import tempfile
import wave

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

SOURCES = {"Mikrofon", "Systemlyd"}


async def run(worker, folder):
    connections = []
    nonempty_audio = set()

    async def speech(socket):
        connections.append(socket)
        assert "language=da-DK" in socket.request.path
        assert socket.request.headers["Ocp-Apim-Subscription-Key"] == "fixture-key"
        sent = False
        try:
            async for frame in socket:
                if not isinstance(frame, bytes):
                    continue
                header_len = int.from_bytes(frame[:2], "big")
                header = frame[2:2 + header_len].decode()
                audio = frame[2 + header_len:]
                request = re.search(r"x-requestid:\s*([^\r\n]+)", header, re.I).group(1)

                async def reply(path, payload):
                    await socket.send(f"Path: {path}\r\nX-RequestId: {request}\r\nContent-Type: application/json\r\n\r\n" + json.dumps(payload))

                if not audio:
                    await reply("turn.end", {})
                    await socket.close()
                    continue
                if len(audio) <= 100 or sent:
                    continue
                assert any(audio), "Expected microphone or system PCM in the SDK stream"
                nonempty_audio.add(socket)
                await reply("turn.start", {"context": {}})
                await reply("speech.startDetected", {"Offset": 0})
                await reply("speech.hypothesis", {"Offset": 0, "Duration": 5000000, "Text": "prøve"})
                await reply("speech.phrase", {"RecognitionStatus": "Success", "DisplayText": "Prøve.", "Offset": 0, "Duration": 5000000})
                sent = True
        except ConnectionClosed:
            pass

    async with serve(speech, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        for offset in [0, 2000]:
            process = await asyncio.create_subprocess_exec(worker, "--azure-live", folder,
                                                           stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE)
            async def send(payload):
                process.stdin.write((json.dumps(payload) + "\n").encode())
                await process.stdin.drain()

            async def read():
                msg = (await asyncio.wait_for(process.stdout.readline(), 20)).decode().strip()
                assert msg and not msg.startswith("LIVE_ERROR") and "fixture-key" not in msg, msg
                return msg

            try:
                start = offset * 16
                await send({"connection": {"endpoint": f"ws://127.0.0.1:{port}/speech/recognition/conversation/cognitiveservices/v1",
                                           "key": "fixture-key", "language": "da-DK"}, "start": [start, start]})
                assert await read() == "LIVE_READY"
                # On resume, previously recorded frames cannot reopen an Azure connection.
                await send([start, start])
                assert await read() == "LIVE_WAIT"
                assert len(connections) == offset // 1000
                partial, final = set(), set()
                while final != SOURCES or partial != SOURCES:
                    await send([start + 32000] * 2)
                    while True:
                        msg = await read()
                        if msg in ("LIVE_NEXT", "LIVE_WAIT"):
                            break
                        tag, data = msg.split(" ", 1)
                        row = json.loads(data)
                        assert row["ms"] == offset, row
                        if tag == "LIVE_PARTIAL" and row["text"] == "prøve":
                            partial.add(row["source"])
                        elif tag == "LIVE_LINE" and row["text"] == "Prøve.":
                            final.add(row["source"])
                    await asyncio.sleep(0.05)
                if offset == 0:
                    process.terminate()  # Recorder's pause closes the SDK worker.
                else:
                    process.stdin.close()  # A disappearing UI must also release both sockets.
                await asyncio.wait_for(process.wait(), 10)
                await asyncio.gather(*(asyncio.wait_for(socket.wait_closed(), 10) for socket in connections))
            finally:
                if process.returncode is None:
                    process.kill()
                    await process.wait()
        assert len(connections) == len(nonempty_audio) == 4


with tempfile.TemporaryDirectory() as directory:
    folder = Path(directory)
    for source in SOURCES:
        with wave.open(str(folder / f"{source}.wav"), "wb") as out:
            out.setparams((1, 2, 16000, 0, "NONE", ""))
            out.writeframes(b"\x80\x21\x80\xdf" * 32000)
    asyncio.run(asyncio.wait_for(run(sys.argv[1], folder), timeout=85))
    print("Both official SDK streams emitted partial and final text before stop, then resumed at the capture timestamp.")
