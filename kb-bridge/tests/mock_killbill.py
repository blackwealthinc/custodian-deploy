#!/usr/bin/env python3
"""Mock Kill Bill for exercising the sweep + verification paths.

Serves just enough of the REST API to test parsing, watermarks, idempotency and
fail-closed verification without the real engine or a tenant.

Every quirk reproduced here was verified against the live engine on .104
(2026-09-18). The mock is only useful to the extent that it reproduces the
UNPLEASANT parts of the real contract -- a permissive mock hides exactly the
bugs the suite exists to catch.

Routes
  GET /1.0/kb/invoices/pagination?offset=&limit=   enumeration ONLY (see below)
  GET /1.0/kb/invoices/byNumber/{n}                FULL invoice | 400 code 4018
  GET /1.0/kb/invoices/{id}                        FULL invoice | 404
  GET /1.0/kb/invoices/{id}/payments               [InvoicePayment]
  GET /1.0/kb/subscriptions/{id}                   subscription | 404
  GET /__hits                                      request log (test-only)
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

# Real engine behaviour: the invoice DETAIL endpoints load invoice items, so
# `amount` and `balance` there are authoritative. The LIST endpoint does not, and
# Kill Bill's DefaultInvoice computes BOTH of those fields FROM the items -- so
# the list reports 0.0/0.0 for an invoice that genuinely carries a balance.
INVOICES = [
    {   # 10: fully paid by ONE successful payment -> the sweep MUST enqueue this
        "invoiceId": "inv-mock-paid-1", "accountId": "acct-mock-1",
        "invoiceNumber": 10, "status": "COMMITTED", "balance": 0.0, "amount": 5.0,
        "currency": "USD", "items": [{"itemType": "RECURRING", "amount": 5.0}],
    },
    {   # 11: committed, part unpaid -> skip
        "invoiceId": "inv-mock-unpaid", "accountId": "acct-mock-2",
        "invoiceNumber": 11, "status": "COMMITTED", "balance": 12.5, "amount": 20.0,
        "currency": "USD", "items": [{"itemType": "RECURRING", "amount": 20.0}],
    },
    {   # 12: draft -> skip
        "invoiceId": "inv-mock-draft", "accountId": "acct-mock-3",
        "invoiceNumber": 12, "status": "DRAFT", "balance": 0.0, "amount": 7.0,
        "currency": "USD", "items": [{"itemType": "RECURRING", "amount": 7.0}],
    },
    {   # 13: fully paid with NO payment at all (settled by credit/CBA).
        # No money moved, so no budget may be granted -- the sweep must refuse it.
        "invoiceId": "inv-mock-credit", "accountId": "acct-mock-4",
        "invoiceNumber": 13, "status": "COMMITTED", "balance": 0.0, "amount": 9.0,
        "currency": "USD", "items": [{"itemType": "EXTERNAL_CHARGE", "amount": 9.0}],
    },
]
# A number that never had an invoice: exercises gap tolerance while walking.
GAP_NUMBER = 14
MISSING_NUMBER = 3      # used by the 4018 end-sentinel test

PAYMENTS = {
    "inv-mock-paid-1": [
        {"paymentId": "pay-mock-10", "paymentNumber": "1", "purchasedAmount": 5.0,
         "transactions": [{"transactionType": "PURCHASE", "status": "SUCCESS",
                           "amount": 5.0}]},
    ],
    # The point of Bug #149: TWO distinct payments on one invoice share an
    # objectId. They must not share an idempotency key.
    "inv-mock-credit": [],
}
# A second, separate invoice whose ONLY payment differs from the one above --
# used to prove two payments on one invoice yield different keys.
PAYMENTS_MULTI = {
    "inv-mock-multi": [
        {"paymentId": "pay-multi-a", "paymentNumber": "1", "purchasedAmount": 4.0,
         "transactions": [{"transactionType": "PURCHASE", "status": "SUCCESS",
                           "amount": 4.0}]},
        {"paymentId": "pay-multi-b", "paymentNumber": "2", "purchasedAmount": 6.0,
         "transactions": [{"transactionType": "PURCHASE", "status": "SUCCESS",
                           "amount": 6.0}]},
    ],
}

SUBSCRIPTIONS = {
    "sub-mock-active": {"subscriptionId": "sub-mock-active", "accountId": "acct-mock-1",
                        "state": "ACTIVE", "productName": "custodian", "planName": "basic"},
    "sub-mock-cancelled": {"subscriptionId": "sub-mock-cancelled", "accountId": "acct-mock-1",
                           "state": "CANCELLED", "productName": "custodian", "planName": "basic"},
}

BY_ID = {i["invoiceId"]: i for i in INVOICES}
BY_NUMBER = {i["invoiceNumber"]: i for i in INVOICES}

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

    def _send_html_404(self):
        body = b"<!doctype html><html><head><title>HTTP Status 404</title></head></html>"
        self.send_response(404)
        self.send_header("Content-Type", "text/html")
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
            # REAL QUIRK: the swagger lists `audit` here but the live engine
            # answers 404 (a Tomcat HTML page) for ANY value of it. Reproduced so
            # the suite catches a sweep that sends `audit` again.
            if "audit" in qs:
                self._send_html_404()
                return
            limit, offset = 100, 0
            for part in qs.split("&"):
                if part.startswith("limit="):
                    limit = int(part.split("=", 1)[1])
                elif part.startswith("offset="):
                    offset = int(part.split("=", 1)[1])
            # REAL QUIRK: items are NOT loaded here, so both money fields come
            # back as 0.0 even for an invoice with a real balance. The sweep must
            # NOT decide anything from this endpoint.
            self._send(200, [
                {**i, "amount": 0.0, "balance": 0.0, "items": []}
                for i in INVOICES[offset:offset + limit]
            ])
            return

        if path.startswith("/1.0/kb/invoices/byNumber/"):
            raw = path.rsplit("/", 1)[-1]
            try:
                num = int(raw)
            except ValueError:
                self._send(400, {"code": 4018, "message": "bad number"})
                return
            inv = BY_NUMBER.get(num)
            if inv is None:
                # REAL behaviour, verified live: a missing number is HTTP 400 with
                # code 4018, NOT a 404.
                self._send(400, {
                    "className": "org.killbill.billing.invoice.api.InvoiceApiException",
                    "code": 4018, "message": f"No invoice could be found for number {num}.",
                })
                return
            self._send(200, inv)          # full invoice, items loaded
            return

        if path.startswith("/1.0/kb/invoices/"):
            rest = path[len("/1.0/kb/invoices/"):]
            if rest.endswith("/payments"):
                inv_id = rest[: -len("/payments")]
                if inv_id in PAYMENTS_MULTI:
                    self._send(200, PAYMENTS_MULTI[inv_id])
                    return
                if inv_id in PAYMENTS:
                    self._send(200, PAYMENTS[inv_id])
                    return
                if inv_id in BY_ID:
                    self._send(200, [])
                    return
                self._send(404, {"message": "invoice not found"})
                return
            inv = BY_ID.get(rest)
            self._send(200, inv) if inv else self._send(404, {"message": "invoice not found"})
            return

        if path.startswith("/1.0/kb/subscriptions/"):
            sub_id = path[len("/1.0/kb/subscriptions/"):]
            sub = SUBSCRIPTIONS.get(sub_id)
            self._send(200, sub) if sub else self._send(404, {"message": "subscription not found"})
            return

        self._send(404, {"message": "mock: no route " + path})


if __name__ == "__main__":
    httpd = ThreadingHTTPServer(("127.0.0.1", 8556), H)
    httpd.daemon_threads = True
    print("mock kill bill on 127.0.0.1:8556", flush=True)
    httpd.serve_forever()
