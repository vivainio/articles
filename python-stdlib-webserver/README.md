# A Tiny HTTP Server with Just the Python Standard Library

*2026-05-28*

Sometimes you don't need Flask, FastAPI, or Starlette. You need a 50-line script that fakes an upstream API while you build the client, or stands in for a webhook during a demo, or serves a couple of JSON blobs from a colleague's laptop. Pulling in a framework — and a virtualenv, and a `requirements.txt`, and a README explaining how to install it — for that is silly.

Python's `http.server` module already ships with everything you need. The default `BaseHTTPRequestHandler` API is just clunky enough that people reach for Flask instead. With about thirty lines of glue you can turn it into something that looks like a real micro-framework: route decorators, path parameters, JSON in and out.

This article walks through that glue. The complete, runnable file is in [`server.py`](server.py) next to this article — copy it and start adding routes.

## The Bare Minimum

Here's what `http.server` gives you out of the box:

```python
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"hello\n")

HTTPServer(("127.0.0.1", 8000), Handler).serve_forever()
```

It works, but every endpoint becomes an `if self.path == ...` ladder inside `do_GET`. Adding a second method means another `do_POST` with its own ladder. We can do better without giving up the zero-dependency promise.

## Goal: Route Decorators

What we want to write:

```python
@route("GET", "/hello")
def hello(req: Request) -> dict:
    return {"message": "hello world"}

@route("GET", "/users/{id}")
def get_user(req: Request, id: str) -> dict:
    return {"id": id, "name": f"user-{id}"}

@route("POST", "/echo")
def echo(req: Request) -> Any:
    return req.json
```

Note that path parameters always arrive as strings — the regex captures text, so if you want an `int` you cast it inside the handler.

That's the target. Now let's build it.

## The Router

A route is a `(method, pattern, function)` tuple. Patterns like `/users/{id}` need to be compiled into something we can match a real path against. A regex is fine:

```python
import re
from typing import Any, Callable

Handler = Callable[..., Any]
ROUTES: list[tuple[str, re.Pattern[str], Handler]] = []

def route(method: str, pattern: str) -> Callable[[Handler], Handler]:
    regex = re.compile("^" + re.sub(r"\{(\w+)\}", r"(?P<\1>[^/]+)", pattern) + "$")
    def decorator(func: Handler) -> Handler:
        ROUTES.append((method, regex, func))
        return func
    return decorator
```

`{id}` becomes a named capture group `(?P<id>[^/]+)`. When the path matches, `match.groupdict()` gives us a dict we can splat into the handler as keyword arguments.

## The Request Object

The handler functions receive a `req` object. We don't need much — the method, the path, parsed query parameters, headers, and (for POSTs) a parsed JSON body:

```python
import json
from http.server import BaseHTTPRequestHandler
from typing import Any
from urllib.parse import urlparse, parse_qs

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
```

`@property` keeps it lazy — if a handler doesn't touch `req.json`, we never parse it.

## The Handler

Now wire it all together. A single `BaseHTTPRequestHandler` subclass dispatches every method through the route table:

```python
from http.server import BaseHTTPRequestHandler, HTTPServer

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
            return self._send(200, result)
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
```

The `do_GET = do_POST = ...` line is the trick that keeps this short. `BaseHTTPRequestHandler` dispatches on method by name, so we alias all of them to the same dispatcher. The override on `log_message` is optional but cleans up the noisy default access log.

## Putting It Together

```python
def main():
    print("listening on http://127.0.0.1:8000")
    HTTPServer(("127.0.0.1", 8000), App).serve_forever()

if __name__ == "__main__":
    main()
```

That's the whole framework — about 50 lines including blanks. Drop your routes above `main()` and you're done.

## Returning Non-JSON

The `_send` helper assumes everything is JSON. For the simulator use case that's usually right, but sometimes you want to return a status code, or HTML, or an empty body. A common pattern is to let the handler return a tuple or a sentinel:

```python
def _send_result(self, result: Any) -> None:
    if isinstance(result, tuple):
        status, body = result
    else:
        status, body = 200, result
    self._send(status, body)
```

Now handlers can write `return 404, {"error": "no such user"}` when they want a specific status.

## Threading

`HTTPServer` is single-threaded — one request at a time. For a simulator that usually doesn't matter, but if your client makes parallel requests and your handlers do anything slow, swap in `ThreadingHTTPServer`:

```python
from http.server import ThreadingHTTPServer
ThreadingHTTPServer(("127.0.0.1", 8000), App).serve_forever()
```

Same API, one thread per request. Don't share mutable state across handlers without a lock.

For the case where you just need to answer a few HTTP requests with canned data, the standard library has had you covered since Python 2. It just needed a tiny bit of sugar on top.
