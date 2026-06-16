"""Reference client for the whispervulkan daemon (stdlib only).

    from whispervulkan import transcribe
    text = transcribe(open("clip.wav", "rb").read())
"""
import os
import json
import urllib.request

URL = os.environ.get("WHISPER_HTTP_URL", "http://127.0.0.1:48450/inference")


def transcribe(wav_bytes: bytes, response_format: str = "text", language: str = "") -> str:
    """POST 16 kHz mono WAV bytes to whispervulkan, return the transcript."""
    boundary = "----whispervulkan"
    parts = []
    fields = {"response_format": response_format}
    if language:
        fields["language"] = language
    for k, v in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    parts.append(
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".encode()
    )
    parts.append(wav_bytes)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    body = b"".join(parts)
    req = urllib.request.Request(
        URL, data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req) as resp:
        raw = resp.read().decode("utf-8", "replace")
    if response_format == "json":
        return json.loads(raw).get("text", raw).strip()
    return raw.strip()


if __name__ == "__main__":
    import sys
    with open(sys.argv[1], "rb") as f:
        print(transcribe(f.read()))
