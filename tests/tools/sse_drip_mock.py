#!/usr/bin/env python3
"""Per-request SSE drip mock for the real-transport repro drivers.

Each response drips chunks that name the request number ("reqK"), so every
turn's content is uniquely identifiable on screen. Logs requests to
requests.log as ground truth for which turns actually reached the API.

Every TOOL_EVERY-th fresh request (one whose body carries no tool result)
streams a bash tool_call instead of content, so the app opens the bash
viewport, runs the command, and re-requests with the tool result attached;
that follow-up (body contains "tool_call_id") streams the final content.
This exercises the tool-viewport walk-up paths a content-only mock never
touches. TOOL_EVERY=0 (default) disables tool rounds.
"""
import http.server
import json
import socketserver
import sys
import threading
import time
import os

count = 0
lock = threading.Lock()
reqlog = open(sys.argv[2] if len(sys.argv) > 2 else "/tmp/xtrepro/requests.log", "w")
tool_every = int(os.environ.get("TOOL_EVERY", "0"))
no_usage_every = int(os.environ.get("NO_USAGE_EVERY", "0"))

def sse(obj):
    return (json.dumps(obj) + "\n\n").encode()

def usage(finish):
    return {"choices": [{"delta": {}, "finish_reason": finish}],
            "usage": {"prompt_tokens": 12, "completion_tokens": 24,
                      "total_tokens": 36, "cached_tokens": 0}}

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def do_POST(self):
        global count
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        with lock:
            count += 1
            k = count
        reqlog.write(f"{time.time():.3f} req {k} tool_result="
                     f"{'tool_call_id' in body}\n")
        reqlog.flush()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        def chunk(data: bytes):
            payload = b"data: " + data
            self.wfile.write(f"{len(payload):X}\r\n".encode() + payload + b"\r\n")
            self.wfile.flush()
        time.sleep(1.2)
        want_tool = (tool_every > 0 and "tool_call_id" not in body
                     and k % tool_every == 0)
        if want_tool:
            # bash tool call: dripped argument bytes, then tool_calls stop
            args = json.dumps({"command": "seq 1 60 | tr '\\n' ' ' "
                                          f"&& echo tool{k}done"})
            for piece in (args[:len(args) // 2], args[len(args) // 2:]):
                chunk(sse({"choices": [{"delta": {"tool_calls": [{
                    "index": 0, "function": {"name": "bash",
                                             "arguments": piece}}]},
                    "finish_reason": ""}]}))
                time.sleep(0.05)
            chunk(sse(usage("tool_calls")))
        elif (no_usage_every > 0 and "tool_call_id" not in body
              and k % no_usage_every == 0):
            # usage-less turn: content with no usage object at the end
            for w in [f"req{k}"] + [f"part{k}c{i}" for i in range(1, 9)]:
                chunk(sse({"choices": [{"delta": {"content": w + " "},
                                        "finish_reason": ""}]}))
                time.sleep(0.025)
            chunk(sse({"choices": [{"delta": {},
                                    "finish_reason": "stop"}]}))
        else:
            for w in [f"req{k}"] + [f"part{k}c{i}" for i in range(1, 9)]:
                chunk(sse({"choices": [{"delta": {"content": w + " "},
                                        "finish_reason": ""}]}))
                time.sleep(0.025)
            chunk(sse(usage("stop")))
        chunk(b"[DONE]\n\n")
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

port = int(sys.argv[1])
socketserver.TCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(("127.0.0.1", port), H) as httpd:
    print(f"http://127.0.0.1:{port}", flush=True)
    httpd.serve_forever()
