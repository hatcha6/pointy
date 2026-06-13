"""Minimal client for the ZKTeco BioTime 8.x REST API.

BioTime is the attendance server the ZKTeco terminals push their punches to.
It exposes a JSON API secured by a JWT obtained from username/password:

- POST /jwt-api-token-auth/                  -> {"token": "..."}
- GET  /personnel/api/employees/             -> paginated employees (emp_code, ...)
- GET  /iclock/api/transactions/             -> paginated punches (emp_code,
                                                punch_time, punch_state, ...)

List endpoints paginate with ?page=&page_size= and return the rows under
either "data" (BioTime style) or "results" (plain DRF style) depending on the
build, so both are handled.
"""

import requests

CONNECT_TIMEOUT_SECONDS = 10
READ_TIMEOUT_SECONDS = 30
PAGE_SIZE = 200


class BioTimeError(Exception):
    """A BioTime request failed (network, auth, or unexpected payload)."""


class BioTimeClient:
    def __init__(self, base_url, username, password):
        self.base_url = (base_url or "").rstrip("/")
        self.username = username
        self.password = password
        self._token = None
        self._session = requests.Session()

    def authenticate(self):
        payload = self._request_json(
            "POST",
            "/jwt-api-token-auth/",
            json={"username": self.username, "password": self.password},
            authenticated=False,
        )
        token = payload.get("token") if isinstance(payload, dict) else None
        if not token:
            raise BioTimeError("BioTime did not return an auth token.")
        self._token = token
        return token

    def iter_employees(self):
        yield from self._iter_pages("/personnel/api/employees/", {})

    def iter_transactions(self, *, start_time=None, end_time=None):
        params = {}
        if start_time is not None:
            params["start_time"] = start_time.strftime("%Y-%m-%d %H:%M:%S")
        if end_time is not None:
            params["end_time"] = end_time.strftime("%Y-%m-%d %H:%M:%S")
        yield from self._iter_pages("/iclock/api/transactions/", params)

    def count_employees(self):
        payload = self._get("/personnel/api/employees/", {"page": 1, "page_size": 1})
        count = payload.get("count") if isinstance(payload, dict) else None
        if count is None:
            raise BioTimeError("BioTime returned an unexpected employee payload.")
        return int(count)

    def _iter_pages(self, path, params):
        page = 1
        while True:
            payload = self._get(path, {**params, "page": page, "page_size": PAGE_SIZE})
            if not isinstance(payload, dict):
                raise BioTimeError("BioTime returned an unexpected list payload.")
            rows = payload.get("data")
            if rows is None:
                rows = payload.get("results")
            if not isinstance(rows, list):
                raise BioTimeError("BioTime returned an unexpected list payload.")
            yield from rows
            if not payload.get("next") or not rows:
                return
            page += 1

    def _get(self, path, params):
        if self._token is None:
            self.authenticate()
        return self._request_json("GET", path, params=params)

    def _request_json(self, method, path, *, params=None, json=None, authenticated=True):
        if not self.base_url:
            raise BioTimeError("BioTime server address is not configured.")
        headers = {}
        if authenticated:
            headers["Authorization"] = f"JWT {self._token}"
        try:
            response = self._session.request(
                method,
                f"{self.base_url}{path}",
                params=params,
                json=json,
                headers=headers,
                timeout=(CONNECT_TIMEOUT_SECONDS, READ_TIMEOUT_SECONDS),
            )
        except requests.RequestException as exc:
            raise BioTimeError(f"Could not reach the BioTime server: {exc}") from exc
        if response.status_code in (401, 403):
            raise BioTimeError("BioTime rejected the configured credentials.")
        if response.status_code >= 400:
            raise BioTimeError(
                f"BioTime returned HTTP {response.status_code} for {path}."
            )
        try:
            return response.json()
        except ValueError as exc:
            raise BioTimeError("BioTime returned a non-JSON response.") from exc
