"""The shopping tools, backed by the store API (Empower's flask-otlp). Same as tools.ts.

The coupon (410, SAVE20 is seeded expired) and the purchase (500, inventory check) fail by
design. Tools report what the store said instead of raising.
"""
import os

import requests

from .session import DEFAULT_FORM, add_items, empty_cart, record_widget

STORE_URL = os.environ.get("STORE_URL", "http://localhost:8080").rstrip("/")
PRODUCT_FIELDS = ("id", "title", "description", "price", "img", "imgcropped")
DEMO_HEADERS = ("se", "customerType", "email", "cexp")


def _trim(product: dict) -> dict:
    return {k: product[k] for k in PRODUCT_FIELDS if k in product}


def _store(method: str, path: str, headers: dict, body=None):
    response = requests.request(
        method,
        f"{STORE_URL}{path}",
        json=body,
        headers={"Content-Type": "application/json", **headers},
        timeout=60,
    )
    try:
        data = response.json() if response.text else {}
    except ValueError:
        data = {"text": response.text}
    return response.status_code, data


def _all_products(headers: dict, slow: bool = False) -> list:
    status, data = _store("GET", "/products?fetch_promotions=true" if slow else "/products", headers)
    if status != 200 or not isinstance(data, list):
        raise RuntimeError(f"GET /products returned HTTP {status}")
    return data


TOOL_SPECS = [
    {
        "toolSpec": {
            "name": "search_products",
            "description": 'Search the Empower Plant catalogue. "under $200" means max_price=200.',
            "inputSchema": {
                "json": {
                    "type": "object",
                    "properties": {
                        "max_price": {"type": "number", "description": "Only products at or below this price, in dollars."},
                        "query": {"type": "string", "description": "Optional text to match in titles and descriptions."},
                    },
                }
            },
        }
    },
    {
        "toolSpec": {
            "name": "add_to_cart",
            "description": 'Add products to the cart by id. "One of each" means quantity 1 of every product just shown.',
            "inputSchema": {
                "json": {
                    "type": "object",
                    "properties": {
                        "items": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {"product_id": {"type": "integer"}, "qty": {"type": "integer"}},
                                "required": ["product_id"],
                            },
                        }
                    },
                    "required": ["items"],
                }
            },
        }
    },
    {
        "toolSpec": {
            "name": "view_cart",
            "description": "Show what is in the customer's cart.",
            "inputSchema": {"json": {"type": "object", "properties": {}}},
        }
    },
    {
        "toolSpec": {
            "name": "start_checkout",
            "description": "Begin checkout and return the prefilled checkout form. Does not apply coupons or buy.",
            "inputSchema": {"json": {"type": "object", "properties": {}}},
        }
    },
    {
        "toolSpec": {
            "name": "apply_coupon",
            "description": "Apply a promo code to the order. The checkout form's code is SAVE20.",
            "inputSchema": {
                "json": {"type": "object", "properties": {"code": {"type": "string"}}, "required": ["code"]}
            },
        }
    },
    {
        "toolSpec": {
            "name": "purchase",
            "description": "Place the order for everything in the cart. Only when the customer explicitly asks to buy.",
            "inputSchema": {"json": {"type": "object", "properties": {}}},
        }
    },
]


def _result(ok: bool, payload: dict, error_type: str | None = None, error_message: str | None = None) -> dict:
    return {"ok": ok, "payload": payload, "error_type": error_type, "error_message": error_message}


def search_products(session, tool_input: dict, headers: dict) -> dict:
    # The shared cexp schedule makes /products extremely slow in some windows, as on the site.
    slow = "products_extremely_slow" in headers.get("cexp", "")
    products = [_trim(p) for p in _all_products(headers, slow)]
    max_price = tool_input.get("max_price")
    if isinstance(max_price, (int, float)):
        products = [p for p in products if (p.get("price") or 0) <= max_price]
    query = str(tool_input.get("query") or "").lower()
    if query:
        products = [
            p for p in products
            if query in str(p.get("title", "")).lower() or query in str(p.get("description", "")).lower()
        ]
    products = products[:6]
    session.last_results = products
    payload = {"products": products, "count": len(products)}
    record_widget(session, "search_products", "products", payload)
    return _result(True, payload)


def add_to_cart(session, tool_input: dict, headers: dict) -> dict:
    requested: dict[int, int] = {}
    for item in tool_input.get("items") or []:
        product_id = int(item.get("product_id"))
        requested[product_id] = requested.get(product_id, 0) + max(1, int(item.get("qty") or 1))
    known = {p["id"]: p for p in session.last_results}
    if any(pid not in known for pid in requested):
        for p in _all_products(headers):
            known.setdefault(p["id"], _trim(p))
    found = [pid for pid in requested if pid in known]
    quantities = {pid: requested[pid] for pid in found}
    add_items(session, [known[pid] for pid in found], quantities)
    payload = {
        "cart": session.cart,
        "added": [{"product_id": pid, "qty": quantities[pid]} for pid in found],
        "unknown_product_ids": [pid for pid in requested if pid not in known],
    }
    record_widget(session, "add_to_cart", "cart", payload)
    return _result(True, payload)


def view_cart(session, tool_input: dict, headers: dict) -> dict:
    payload = {"cart": session.cart, "promo": session.promo}
    record_widget(session, "view_cart", "cart", payload)
    return _result(True, payload)


def start_checkout(session, tool_input: dict, headers: dict) -> dict:
    if not session.cart["items"]:
        payload = {"error": "The cart is empty; add something first."}
        record_widget(session, "start_checkout", "checkout", payload)
        return _result(True, payload)
    if session.form is None:
        session.form = dict(DEFAULT_FORM)
    payload = {"cart": session.cart, "form": session.form, "promo": session.promo}
    record_widget(session, "start_checkout", "checkout", payload)
    return _result(True, payload)


def apply_coupon(session, tool_input: dict, headers: dict) -> dict:
    code = str(tool_input.get("code") or "SAVE20").strip()
    status, body = _store("POST", "/apply-promo-code", headers, {"value": code})
    body = body if isinstance(body, dict) else {}
    if status == 200:
        session.promo = body.get("promo_code")
        payload = {"ok": True, "code": code, "promo": session.promo}
        record_widget(session, "apply_coupon", "promo", payload)
        return _result(True, payload)
    error = body.get("error") if isinstance(body.get("error"), dict) else {}
    payload = {
        "ok": False,
        "code": code,
        "status": status,
        "error_code": error.get("code", "error"),
        "message": error.get("message", f"Could not apply {code} (HTTP {status})."),
    }
    record_widget(session, "apply_coupon", "promo", payload)
    return _result(
        False,
        payload,
        f"apply_coupon.{payload['error_code']}",
        f"{code} was rejected (HTTP {status}): {payload['message']}",
    )


def purchase(session, tool_input: dict, headers: dict) -> dict:
    if not session.cart["items"]:
        payload = {"ok": False, "message": "The cart is empty."}
        record_widget(session, "purchase", "confirmation", payload)
        return _result(True, payload)
    # A string, not a boolean: the store compares validate_inventory == "true".
    # checkout_success is the healthy window of the shared cexp schedule.
    validate = "false" if "checkout_success" in headers.get("cexp", "") else "true"
    status, body = _store(
        "POST",
        "/checkout?v2=true",
        headers,
        {"cart": session.cart, "form": session.form or DEFAULT_FORM, "validate_inventory": validate},
    )
    if status == 200:
        payload = {
            "ok": True,
            "status": (body or {}).get("status", "success") if isinstance(body, dict) else "success",
            "order_total": session.cart["total"],
            "item_count": sum(session.cart["quantities"].values()),
        }
        session.cart, session.promo, session.form = empty_cart(), None, None
        record_widget(session, "purchase", "confirmation", payload)
        return _result(True, payload)
    payload = {"ok": False, "status": status, "message": f"Checkout failed (HTTP {status}).", "detail": body}
    record_widget(session, "purchase", "confirmation", payload)
    return _result(False, payload, f"purchase.http_{status}", f"Checkout failed (HTTP {status}): {str(body)[:300]}")


TOOLS = {
    "search_products": search_products,
    "add_to_cart": add_to_cart,
    "view_cart": view_cart,
    "start_checkout": start_checkout,
    "apply_coupon": apply_coupon,
    "purchase": purchase,
}
