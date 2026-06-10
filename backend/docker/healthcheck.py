import json
import sys
import urllib.error
import urllib.request


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000/readyz/"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            body = response.read(4096)
            if response.status >= 400:
                return 1
    except (OSError, urllib.error.URLError):
        return 1

    try:
        payload = json.loads(body.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return 1
    return 0 if payload.get("status") in {"ok", "ready"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
