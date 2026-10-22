#!/usr/bin/env python3
"""Forward MCP stdio to Symphony's tool broker. This process never sees tracker API keys."""

import json
import os
import socket
import sys

port = int(os.environ["SYMPHONY_TOOL_PORT"])
token = os.environ.get("SYMPHONY_TOOL_TOKEN", "")
sock = socket.create_connection(("127.0.0.1", port))
stream = sock.makefile("rwb")

for raw in sys.stdin:
    line = raw.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        continue
    if message.get("id") is None:
        continue
    payload = json.dumps({"token": token, "message": message}).encode() + b"\n"
    stream.write(payload)
    stream.flush()
    response = stream.readline()
    if not response:
        break
    sys.stdout.buffer.write(response)
    sys.stdout.buffer.flush()
