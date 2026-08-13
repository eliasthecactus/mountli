#!/usr/bin/env python3
"""Reset the least-privilege WebDAV App Review collection."""

from __future__ import annotations

import base64
import os
import ssl
import urllib.error
import urllib.parse
import urllib.request

base = os.environ["APP_REVIEW_WEBDAV_URL"].rstrip("/")
username = os.environ["APP_REVIEW_WEBDAV_USERNAME"]
password = os.environ["APP_REVIEW_WEBDAV_PASSWORD"]
parsed = urllib.parse.urlsplit(base)
if parsed.scheme != "https" or not parsed.netloc:
    raise SystemExit("App Review fixture URL must be absolute HTTPS")
auth = base64.b64encode(f"{username}:{password}".encode()).decode()
context = ssl.create_default_context()
collection = f"{base}/review-fixture"


def request(method: str, url: str, data: bytes | None = None, allowed: set[int] = {200, 201, 204}) -> None:
    operation = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Authorization": f"Basic {auth}", "Content-Type": "text/plain; charset=utf-8"},
    )
    try:
        with urllib.request.urlopen(operation, context=context, timeout=30) as response:
            if response.status not in allowed:
                raise SystemExit(f"WebDAV {method} returned unexpected HTTP {response.status}")
    except urllib.error.HTTPError as error:
        if error.code not in allowed:
            raise SystemExit(f"WebDAV {method} failed with HTTP {error.code}") from error


request("DELETE", collection, allowed={200, 204, 404})
request("MKCOL", collection, allowed={201})
request(
    "PUT",
    f"{collection}/Welcome.txt",
    b"Welcome to the MOUNTLI App Review fixture. You may duplicate and edit this file.\n",
    allowed={200, 201, 204},
)
request("PROPFIND", collection, allowed={207})
print("App Review WebDAV fixture reset and verified")
