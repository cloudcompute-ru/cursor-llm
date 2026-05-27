#!/usr/bin/env python3
"""
Cursor-friendly proxy in front of vLLM's OpenAI-compatible server.

Why this exists
---------------
Cursor reads `max_model_len` from /v1/models and tries to fill prompts
right up to that ceiling. Empirically (cursor-llm production traffic)
it overshoots by exactly +1 token every single time, regardless of
the value: 16384→16385, 32768→32769, 65536→65537. Plausible cause is
Cursor's own tokenizer (cl100k-style) disagreeing with Qwen's
tokenizer by 1 token on the assistant message wrappers.

Cursor offers no UI knob for this. The only way to keep the connection
healthy is to advertise a smaller `max_model_len` in /v1/models than
vLLM actually accepts, leaving a safety margin.

What this does
--------------
  - Listens on $LISTEN_PORT (default 8000), which is what cloudflared
    exposes publicly.
  - Forwards every request to vLLM on $UPSTREAM_PORT (default 8001),
    streaming the response back unmodified — including SSE for
    `stream=true` chat completions.
  - For GET /v1/models specifically: parses the JSON response and
    rewrites every model entry's `max_model_len` to
    $ADVERTISED_MAX_MODEL_LEN (default 60000). This is the only
    field Cursor uses to size its prompt budget.

Stdlib only — no fastapi / uvicorn / httpx install footprint, so the
provisioning step that ships this can stay a single tiny `cp`.
"""

from __future__ import annotations

import argparse
import http.client
import http.server
import json
import os
import socket
import socketserver
import sys
import threading

UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 8001
ADVERTISED_MAX_MODEL_LEN = 60000

# Per-request timeout to upstream. Long enough for full prompt
# processing on a slow GPU + long generation, short enough that a
# wedged engine doesn't keep client sockets open forever.
UPSTREAM_TIMEOUT_S = 900


class Proxy(http.server.BaseHTTPRequestHandler):
    # HTTP/1.1 keeps connections open; combined with ThreadingMixIn
    # below this lets multiple Cursor requests share one TCP socket
    # and stream simultaneously.
    protocol_version = "HTTP/1.1"

    # Keep the access log quiet; we'd just be duplicating vLLM's
    # output and spamming /var/log/cloudflared.log on every Cursor
    # tab keystroke.
    def log_message(self, format, *args):
        pass

    def _forward(self, method: str) -> None:
        body_len = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(body_len) if body_len else None

        # Strip Host so http.client sets it to the upstream socket.
        # Pass everything else through (Authorization, Content-Type,
        # Accept, x-stainless-* etc).
        fwd_headers = {
            k: v for k, v in self.headers.items() if k.lower() != "host"
        }

        try:
            conn = http.client.HTTPConnection(
                UPSTREAM_HOST, UPSTREAM_PORT, timeout=UPSTREAM_TIMEOUT_S
            )
            conn.request(method, self.path, body=body, headers=fwd_headers)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as e:
            try:
                self.send_error(502, f"upstream error: {e}")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return

        # Special-case: rewrite /v1/models so Cursor sees a smaller
        # context cap than vLLM actually enforces. We only rewrite on
        # success — if upstream errored, pass it through verbatim so
        # the user sees the real failure.
        if (
            method == "GET"
            and self.path.startswith("/v1/models")
            and resp.status == 200
        ):
            raw = resp.read()
            try:
                obj = json.loads(raw)
                for m in obj.get("data", []) or []:
                    if isinstance(m, dict):
                        m["max_model_len"] = ADVERTISED_MAX_MODEL_LEN
                raw = json.dumps(obj).encode("utf-8")
            except (ValueError, TypeError):
                # Upstream said 200 but body wasn't valid JSON — fall
                # back to passthrough rather than 500ing.
                pass
            self._send_buffered(resp.status, resp.getheaders(), raw)
            return

        # Generic streaming passthrough — works for chat completions
        # with stream=true (SSE) and for plain JSON responses too.
        self._send_streamed(resp)

    def _send_buffered(self, status: int, headers, body: bytes) -> None:
        try:
            self.send_response(status)
            for k, v in headers:
                # We're rewriting body length and serving non-chunked,
                # so drop framing headers from upstream.
                if k.lower() in ("content-length", "transfer-encoding"):
                    continue
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_streamed(self, resp) -> None:
        try:
            self.send_response(resp.status)
            # Drop transfer-encoding because http.client already
            # de-chunked the body for us; we'll re-chunk via
            # `Transfer-Encoding: chunked` ourselves to keep streams
            # working with HTTP/1.1.
            for k, v in resp.getheaders():
                if k.lower() == "transfer-encoding":
                    continue
                if k.lower() == "content-length":
                    # Upstream may set an explicit length only for
                    # non-streaming responses. Forward it as-is.
                    self.send_header(k, v)
                    continue
                self.send_header(k, v)
            # Force close to keep things simple — Cursor opens a fresh
            # connection per request anyway.
            self.send_header("Connection", "close")
            self.end_headers()

            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    break
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self._forward("GET")

    def do_POST(self):
        self._forward("POST")

    def do_PUT(self):
        self._forward("PUT")

    def do_DELETE(self):
        self._forward("DELETE")

    def do_PATCH(self):
        self._forward("PATCH")

    def do_OPTIONS(self):
        self._forward("OPTIONS")


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    # Reuse the port immediately after a restart instead of waiting
    # for the kernel TIME_WAIT timeout.
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--listen-port",
        type=int,
        default=int(os.environ.get("PROXY_LISTEN_PORT", "8000")),
    )
    p.add_argument(
        "--upstream-port",
        type=int,
        default=int(os.environ.get("VLLM_INTERNAL_PORT", "8001")),
    )
    p.add_argument(
        "--advertised-max-model-len",
        type=int,
        default=int(os.environ.get("ADVERTISED_MAX_MODEL_LEN", "60000")),
    )
    args = p.parse_args()

    global UPSTREAM_PORT, ADVERTISED_MAX_MODEL_LEN
    UPSTREAM_PORT = args.upstream_port
    ADVERTISED_MAX_MODEL_LEN = args.advertised_max_model_len

    server = ThreadedHTTPServer(("0.0.0.0", args.listen_port), Proxy)
    print(
        f"[cc-proxy] :{args.listen_port} → 127.0.0.1:{args.upstream_port} "
        f"(advertise max_model_len={args.advertised_max_model_len})",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
