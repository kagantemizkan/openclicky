"""Keeps Ahenk Cep loaded and synthesizes speech for the OpenClicky app.

Speaks one JSON object per line over stdin/stdout and opens no port. It exits
when stdin closes, so it can't outlive the app, even after a crash.

    in:  {"id": 1, "text": "merhaba"}
    out: {"ready": true}                  once, after warm-up
         {"id": 1, "wav": "<base64>"}     or {"id": 1, "error": "..."}

Usage: python -I ahenk_tts_server.py <model directory>
"""
import base64
import io
import json
import os
import sys

# Libraries that print to stdout must not corrupt the protocol.
protocol = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
os.dup2(2, 1)
sys.stdin.reconfigure(encoding="utf-8")

sys.path.insert(0, sys.argv[1])

import soundfile as sf  # noqa: E402
from ahenk_cep import AhenkCep  # noqa: E402


def reply(message):
    protocol.write(json.dumps(message) + "\n")


def synthesize(tts, text):
    audio, sample_rate = tts.say(text)
    buffer = io.BytesIO()
    sf.write(buffer, audio, sample_rate, format="WAV", subtype="PCM_16")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def main():
    tts = AhenkCep(f"{sys.argv[1]}/student.pt", f"{sys.argv[1]}/decoder.pt")
    # The first call is far slower than the rest, so absorb it here.
    tts.say("Merhaba.")
    reply({"ready": True})

    for line in sys.stdin:
        request_id = None
        try:
            request = json.loads(line)
            request_id = request["id"]
            reply({"id": request_id, "wav": synthesize(tts, request["text"])})
        except Exception as error:  # A bad request must not kill the voice.
            reply({"id": request_id, "error": str(error)})


if __name__ == "__main__":
    main()
