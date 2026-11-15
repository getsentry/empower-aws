"""In-memory chat sessions, keyed by the x-conversation-id header the chat widget sends.

Same model as the TypeScript agent's session.ts. One process serves the agent, so there is
no cross-instance state to share; a lock keeps the session table safe across turn threads.
"""
import json
import threading
import time
from dataclasses import dataclass, field

# Same defaults as Empower's CheckoutForm.jsx, so both checkouts send the same form.
DEFAULT_FORM = {
    "email": "plant.lover@example.com",
    "subscribe": "",
    "firstName": "Jane",
    "lastName": "Greenthumb",
    "address": "123 Main Street",
    "city": "San Francisco",
    "country": "United States of America",
    "state": "CA",
    "zipCode": "94122",
    "promoCode": "SAVE20",
}

TTL_SECONDS = 30 * 60


def empty_cart():
    return {"items": [], "quantities": {}, "total": 0}


@dataclass
class Session:
    conversation_id: str
    history: list = field(default_factory=list)
    cart: dict = field(default_factory=empty_cart)
    last_results: list = field(default_factory=list)
    promo: object = None
    form: dict | None = None
    last_tool: str | None = None
    pending_widgets: list = field(default_factory=list)
    last_seen: float = field(default_factory=time.time)
    lock: threading.Lock = field(default_factory=threading.Lock)


_sessions: dict[str, Session] = {}
_table_lock = threading.Lock()


def get_session(conversation_id: str) -> Session:
    now = time.time()
    with _table_lock:
        for key in [k for k, s in _sessions.items() if now - s.last_seen > TTL_SECONDS]:
            del _sessions[key]
        session = _sessions.get(conversation_id)
        if session is None:
            session = _sessions[conversation_id] = Session(conversation_id)
        session.last_seen = now
        return session


def record_widget(session: Session, tool: str, widget_type: str, data) -> None:
    session.last_tool = tool
    session.pending_widgets.append({"type": widget_type, "tool": tool, "data": data})


def drain_widgets(session: Session) -> list:
    widgets, session.pending_widgets = session.pending_widgets, []
    return widgets


def add_items(session: Session, products: list, quantities: dict) -> None:
    cart = session.cart
    known = {p["id"] for p in cart["items"]}
    for p in products:
        if p["id"] not in known:
            cart["items"].append(p)
            known.add(p["id"])
    for product_id, qty in quantities.items():
        key = str(product_id)
        cart["quantities"][key] = cart["quantities"].get(key, 0) + qty
    total = sum((p.get("price") or 0) * cart["quantities"].get(str(p["id"]), 0) for p in cart["items"])
    cart["total"] = round(total, 2)


def trim_history(history: list) -> list:
    """Older tool results are shortened, not dropped: dropping them made the model decide
    its earlier replies were unsupported. The toolUse/toolResult pairs stay, as Bedrock
    requires."""
    seen = 0
    for message in reversed(history):
        for block in message.get("content", []):
            result = block.get("toolResult")
            if not result:
                continue
            seen += 1
            if seen > 1:
                text = json.dumps(result.get("content", []))
                if len(text) > 1500:
                    result["content"] = [
                        {"text": f"{text[:1500]}… (shortened; the customer already saw this result)"}
                    ]
    return history
