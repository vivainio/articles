"""Tiny HTTP server library built on http.server with route decorators.

Usage:

    from tinyserver import route, Request, serve

    @route("GET", "/hello")
    def hello(req: Request) -> dict:
        return {"message": "hello"}

    serve()
"""

from __future__ import annotations

import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse


Handler = Callable[..., Any]
ROUTES: list[tuple[str, re.Pattern[str], Handler]] = []


def route(method: str, pattern: str) -> Callable[[Handler], Handler]:
    parts = re.split(r"(\{\w+\})", pattern)
    regex_text = "".join(
        rf"(?P<{part[1:-1]}>[^/]+)" if part.startswith("{") else re.escape(part)
        for part in parts
    )
    regex = re.compile("^" + regex_text + "$")

    def decorator(func: Handler) -> Handler:
        ROUTES.append((method, regex, func))
        return func

    return decorator


class Request:
    def __init__(self, handler: BaseHTTPRequestHandler) -> None:
        parsed = urlparse(handler.path)
        self.method: str = handler.command
        self.path: str = parsed.path
        self.query: dict[str, str] = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        self.headers = handler.headers
        length = int(handler.headers.get("Content-Length", 0))
        self.body: bytes = handler.rfile.read(length) if length else b""

    @property
    def json(self) -> Any:
        return json.loads(self.body) if self.body else None


class App(BaseHTTPRequestHandler):
    def _dispatch(self) -> None:
        req = Request(self)
        for method, regex, func in ROUTES:
            if method != req.method:
                continue
            m = regex.match(req.path)
            if not m:
                continue
            try:
                result = func(req, **m.groupdict())
            except Exception as e:
                return self._send(500, {"error": str(e)})
            if isinstance(result, tuple):
                status, body = result
            else:
                status, body = 200, result
            return self._send(status, body)
        self._send(404, {"error": "not found"})

    def _send(self, status: int, body: Any) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _dispatch

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.command} {self.path} -> {args[1]}")


def serve(host: str = "127.0.0.1", port: int = 8000) -> None:
    print(f"listening on http://{host}:{port}")
    ThreadingHTTPServer((host, port), App).serve_forever()
