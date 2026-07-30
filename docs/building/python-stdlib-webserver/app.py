"""Example app using tinyserver. Run: python app.py"""

from __future__ import annotations

from typing import Any

from tinyserver import Request, route, serve


@route("GET", "/hello")
def hello(req: Request) -> dict:
    return {"message": "hello world"}


@route("GET", "/users/{id}")
def get_user(req: Request, id: str) -> Any:
    if id == "0":
        return 404, {"error": "no such user"}
    return {"id": id, "name": f"user-{id}"}


@route("POST", "/echo")
def echo(req: Request) -> Any:
    return req.json


if __name__ == "__main__":
    serve()
