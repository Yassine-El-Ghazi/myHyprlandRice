#!/usr/bin/python3
"""Read Elephant's JSON query protocol, including empty-result status frames."""

import json
import os
from pathlib import Path
import socket
import struct
import sys
import time


def query(limit):
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", ""))
    if not runtime.is_absolute() or not 1 <= limit <= 10000:
        raise ValueError("invalid clipboard query")
    request = json.dumps({"providers": ["clipboard"], "maxresults": limit}).encode()
    deadline = time.monotonic() + 5
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(runtime / "elephant/elephant.sock"))
        connection.sendall(b"\x00\x01" + struct.pack(">I", len(request)) + request)

        def receive(length):
            result = bytearray()
            while len(result) < length:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("clipboard query timed out")
                connection.settimeout(remaining)
                chunk = connection.recv(length - len(result))
                if not chunk:
                    raise ValueError("incomplete clipboard response")
                result.extend(chunk)
            return bytes(result)

        responses = []
        while True:
            kind, length = struct.unpack(">BI", receive(5))
            if kind in (254, 255):  # No results / query complete; no JSON payload.
                if length:
                    raise ValueError("invalid clipboard status")
                if kind == 255:
                    return responses
                continue
            if kind not in (0, 1) or not 0 < length <= 1024 * 1024:
                raise ValueError("invalid clipboard frame")
            response = json.loads(receive(length))
            if not isinstance(response, dict) or not isinstance(response.get("item"), dict):
                raise ValueError("invalid clipboard item")
            responses.append(response)
            if len(responses) > limit:
                raise ValueError("clipboard response limit exceeded")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("expected query limit")
        # Buffer until query completion so a failed query never looks complete.
        for response in query(int(sys.argv[1])):
            print(json.dumps(response))
    except (OSError, ValueError, TypeError):
        print("Could not query Elephant clipboard history.", file=sys.stderr)
        sys.exit(1)
