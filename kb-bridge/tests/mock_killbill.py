#!/usr/bin/env python3
"""Minimal mock Kill Bill for exercising the sweep + verification paths.

Serves just enough of the REST API to test parsing and watermarks without
needing the real engine or a tenant. Invoice field names are taken from the
live swagger (definitions/Invoice): status DRAFT|COMMITTED|VOID, balance,
amount, invoiceId, accountId, invoiceNumber.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

INVOICES = [
    {   # fully paid -> the sweep MUST enqueue this
        "invoiceId": "inv-mock-paid-1", "accountId": "acct-mock-1",
        "invoiceNumber": 10, "status": "COMMITTED", "balance": 0.0, "amount": 5.0,
        "currency": "USD",
    },
    {   # committed but partially unpaid -> skip
        "invoiceId": "inv-mock-unpaid", "accountId": "acct-mock-2",
        "invoiceNumber": 11, "status": "COMMITTED", "balance": 12.5, "amount": 20.0,
        "currency": "USD",
    },
    {   # draft -> skip
        "invoiceId": "inv-mock-draft", "accountId": "acct-mock-3",
        "invoiceNumber": 12, "status": "DRAFT", "balance": 0.0, "amount": 7.0,
        "currency": "USD",
    },
]
BY_ID = {i["invoiceId"]: i for i in INVOICES}

HITS = []


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        u = urlparse(self.path)
        path, qs = u.path, u.query
        HITS.append(path + ("?" + qs if qs else ""))

        if path == "/__hits":
            self._send(200, HITS)
            return
        if path == "/1.0/kb/invoices/pagination":
            # Mirror a REAL quirk of Kill Bill 0.24.21: the swagger lists `audit`
            # as an optional query param here, but the live engine answers 404
            # (an HTML Tomcat page) for ANY value of it. The mock reproduces that
            # so the test suite catches a sweep that sends `audit`.
            if "audit" in qs:
                body = b"<!doctype html><html><head><title>HTTP Status 404</title></head></html>"
                self.send_response(404)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                return
            limit = 100
            offset = 0
            for part in qs.split("&"):
                if part.startswith("limit="):
                    limit = int(part.split("=", 1)[1])
                elif part.startswith("offset="):
                    offset = int(part.split("=", 1)[1])
            # REAL QUIRK, verified live on .104 (2026-09-18): this endpoint does NOT
            # load invoice items, and Kill Bill computes BOTH `amount`
            # (getChargedAmount) and `balance` (getBalance) FROM those items. With
            # them unloaded, EVERY invoice reports amount=0.0 / balance=0.0 -- even
            # one genuinely carrying a $12.50 balance. An earlier version of this
            # mock returned the true values here, which is precisely why the suite
            # passed while the real sweep was manufacturing false
            # INVOICE_PAYMENT_SUCCESS events for unpaid invoices. Reproduced now so
            # the suite fails if the sweep trusts these fields instead of re-reading
            # the invoice by id.
            self._send(200, [
                {**i, "amount": 0.0, "balance": 0.0, "items": []}
                for i in INVOICES[offset:offset + limit]
            ])
            return

        prefix = "/1.0/kb/invoices/"
        if path.startswith(prefix):
            inv_id = path[len(prefix):]
            inv = BY_ID.get(inv_id)
            if inv is None:
                self._send(404, {"message": "invoice not found"})
            else:
                self._send(200, inv)
            return

        self._send(404, {"message": "mock: no route " + path})


if __name__ == "__main__":
    httpd = ThreadingHTTPServer(("127.0.0.1", 8556), H)
    httpd.daemon_threads = True
    print("mock kill bill on 127.0.0.1:8556", flush=True)
    httpd.serve_forever()
