"""One chat turn: stream Claude on Bedrock, run at most one shopping tool, stream the reply.

A port of the TypeScript agent's agent.ts. Bedrock calls get gen_ai.chat spans from the
Sentry Python SDK's boto3 integration automatically; the agent and tool spans below are
what a customer calling Bedrock directly would add themselves.
"""
import json
import os

import boto3
import sentry_sdk
from botocore.config import Config
from botocore.exceptions import ClientError

from .session import drain_widgets, trim_history
from .tools import TOOL_SPECS, TOOLS

AGENT_NAME = "Shopping Agent"

# Primary and fallback inference profiles. Bedrock occasionally returns
# ServiceUnavailableException; boto3 retries, then the agent switches profile.
MODELS = {
    "sonnet": [
        os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-5-5"),
        os.environ.get("FALLBACK_MODEL_ID", "global.anthropic.claude-sonnet-5-5"),
    ],
    "haiku": [
        os.environ.get("HAIKU_MODEL_ID", "us.anthropic.claude-haiku-5-5"),
        os.environ.get("HAIKU_FALLBACK_MODEL_ID", "global.anthropic.claude-haiku-5-5"),
    ],
}
FALLBACK_ERRORS = {
    "ServiceUnavailableException",
    "ThrottlingException",
    "ModelNotReadyException",
    "AccessDeniedException",
}
PROMPT_CACHE = os.environ.get("PROMPT_CACHE", "true") == "true"

bedrock = boto3.client(
    "bedrock-runtime",
    region_name=os.environ.get("AWS_REGION", "us-east-1"),
    config=Config(retries={"max_attempts": 4, "mode": "adaptive"}, read_timeout=120),
)

SYSTEM_PROMPT = """You are the Empower Plant shopping assistant, talking to a customer in the storefront's chat widget.

Use exactly ONE tool per customer message, then reply. Never chain actions:
- Finding products: search_products. "under $200" is max_price=200.
- add_to_cart takes product ids. "One of each" means quantity 1 of every product the customer was just shown.
- view_cart shows the cart. start_checkout returns the prefilled checkout form.
- apply_coupon only when the customer asks for a coupon; the checkout form's code is SAVE20.
- purchase only when the customer explicitly asks to buy, purchase or place the order.
Starting checkout is not applying a coupon, and neither one is buying.

Do not ask for confirmation before searching, adding to the cart or starting checkout.
If a tool fails, say so in one sentence and do not try another tool.
Keep replies to one short sentence. The chat shows products, the cart, the checkout form and errors as cards, so never list them or repeat prices.
Never ask for payment details; the checkout form is prefilled."""

# Which badge the chat shows for each tool, matching Empower's agent ids.
TOOL_AGENTS = {
    "search_products": "plant",
    "add_to_cart": "shopping",
    "view_cart": "shopping",
    "start_checkout": "shopping",
    "apply_coupon": "shopping",
    "purchase": "shopping",
}
AGENTS = {"manager": "Manager Agent", "plant": "Plant Agent", "shopping": "Shopping Agent"}


def agent_ref(agent_id: str = "manager") -> dict:
    agent_id = agent_id if agent_id in AGENTS else "manager"
    return {"id": agent_id, "name": AGENTS[agent_id]}


STATUS_LABELS = {
    "search_products": "Checking the catalogue…",
    "add_to_cart": "Updating your cart…",
    "view_cart": "Getting your cart…",
    "start_checkout": "Working on your order…",
    "apply_coupon": "Applying your coupon…",
    "purchase": "Placing your order…",
}

PILLS_INITIAL = [{"id": "chat-pill-show-products", "label": "Show me plants under $200"}]
PILLS_CHECKOUT = [
    {"id": "chat-pill-apply-coupon", "label": "Apply Coupon"},
    {"id": "chat-pill-purchase", "label": "Purchase"},
]
PILLS = {
    "search_products": [{"id": "chat-pill-add-all", "label": "Add one of each to the cart"}],
    "add_to_cart": [{"id": "chat-pill-checkout", "label": "Checkout"}],
    "view_cart": [{"id": "chat-pill-checkout", "label": "Checkout"}],
    "start_checkout": PILLS_CHECKOUT,
    "apply_coupon": PILLS_CHECKOUT,
    "purchase": PILLS_INITIAL,
}

# The chat's buttons send these exact messages. For them the model is offered only that
# button's tool, so a demo step can't be skipped; it still makes the call and writes the
# arguments, so the Sentry data is real. Free text gets every tool.
BUTTON_TOOLS = {
    "show me plants under $200": "search_products",
    "add one of each to the cart": "add_to_cart",
    "checkout": "start_checkout",
    "apply coupon": "apply_coupon",
    "purchase": "purchase",
}


def _converse_stream(model_id: str, messages: list, emit, only_tool: str | None):
    system = [{"text": SYSTEM_PROMPT}]
    if PROMPT_CACHE:
        system.append({"cachePoint": {"type": "default"}})
    if only_tool:
        tools = [t for t in TOOL_SPECS if t["toolSpec"]["name"] == only_tool]
    elif PROMPT_CACHE:
        tools = [*TOOL_SPECS, {"cachePoint": {"type": "default"}}]
    else:
        tools = TOOL_SPECS
    response = bedrock.converse_stream(
        modelId=model_id,
        system=system,
        messages=messages,
        toolConfig={"tools": tools},
        inferenceConfig={"maxTokens": 1024},
    )

    content: list = []
    text = ""
    tool = None
    stop_reason = None

    def flush_text():
        nonlocal text
        if text:
            content.append({"text": text})
            emit("message_end", {"agent": agent_ref()})
            text = ""

    for event in response["stream"]:
        if "contentBlockStart" in event and "toolUse" in event["contentBlockStart"].get("start", {}):
            flush_text()
            start = event["contentBlockStart"]["start"]["toolUse"]
            tool = {"toolUseId": start["toolUseId"], "name": start["name"], "input": ""}
        elif "contentBlockDelta" in event:
            delta = event["contentBlockDelta"]["delta"]
            if "text" in delta:
                text += delta["text"]
                emit("token", {"text": delta["text"]})
            elif "toolUse" in delta and tool is not None:
                tool["input"] += delta["toolUse"].get("input", "")
        elif "contentBlockStop" in event and tool is not None:
            try:
                tool_input = json.loads(tool["input"]) if tool["input"] else {}
            except ValueError:
                tool_input = {}
            content.append({"toolUse": {"toolUseId": tool["toolUseId"], "name": tool["name"], "input": tool_input}})
            tool = None
        elif "messageStop" in event:
            stop_reason = event["messageStop"].get("stopReason")
    flush_text()
    return {"message": {"role": "assistant", "content": content}, "stop_reason": stop_reason}


def _converse_with_fallback(models: list, messages: list, emit, only_tool: str | None = None):
    """Try the model's profiles in order; switch only on errors a retry won't fix in time."""
    for i, model_id in enumerate(models):
        try:
            return _converse_stream(model_id, messages, emit, only_tool)
        except ClientError as error:
            code = error.response.get("Error", {}).get("Code", "")
            if code not in FALLBACK_ERRORS or i == len(models) - 1:
                raise
            sentry_sdk.logger.warning(
                f"Bedrock {code} on {model_id}; falling back to {models[i + 1]}",
                attributes={"gen_ai.request.model": model_id, "error.type": code},
            )
    raise RuntimeError("no Bedrock model configured")


def _run_tool(session, block: dict, headers: dict) -> dict:
    name = block.get("name") or "unknown"
    with sentry_sdk.start_span(op="gen_ai.execute_tool", name=f"execute_tool {name}") as span:
        span.set_data("gen_ai.operation.name", "execute_tool")
        span.set_data("gen_ai.tool.name", name)
        span.set_data("gen_ai.tool.type", "function")
        span.set_data("gen_ai.agent.name", AGENT_NAME)
        span.set_data("gen_ai.tool.call.arguments", json.dumps(block.get("input") or {}))
        impl = TOOLS.get(name)
        if impl is None:
            span.set_status("internal_error")
            return {"ok": False, "payload": {"error": f"Unknown tool {name}"}}
        try:
            result = impl(session, block.get("input") or {}, headers)
        except Exception as error:  # noqa: BLE001 - reported, then handed to the model
            span.set_status("internal_error")
            span.set_data("error.type", type(error).__name__)
            sentry_sdk.capture_exception(error)
            return {"ok": False, "payload": {"error": str(error)}}
        span.set_data("gen_ai.tool.call.result", json.dumps(result["payload"], default=str)[:2000])
        if not result["ok"]:
            # A handled failure: the tool returned the store's error instead of raising.
            # Marking the span is what puts it in Explore -> Agents' tool errors.
            span.set_status("internal_error")
            span.set_data("error.type", result.get("error_type") or "tool_error")
            sentry_sdk.logger.warning(
                result.get("error_message") or f"{name} failed", attributes={"gen_ai.tool.name": name}
            )
        else:
            sentry_sdk.logger.info(f"{name} succeeded", attributes={"gen_ai.tool.name": name})
        return result


def run_turn(session, user_message: str, headers: dict, model_key: str, emit) -> None:
    models = MODELS.get(model_key, MODELS["sonnet"])
    session.pending_widgets = []
    reply = ""

    def capture(event: str, data: dict) -> None:
        nonlocal reply
        if event == "token":
            reply += str(data.get("text", ""))
        emit(event, data)

    with sentry_sdk.start_span(op="gen_ai.invoke_agent", name=f"invoke_agent {AGENT_NAME}") as agent_span:
        agent_span.set_data("gen_ai.operation.name", "invoke_agent")
        agent_span.set_data("gen_ai.agent.name", AGENT_NAME)
        agent_span.set_data("gen_ai.request.model", models[0])
        agent_span.set_data(
            "gen_ai.input.messages",
            json.dumps([{"role": "user", "parts": [{"type": "text", "content": user_message}]}]),
        )
        messages = [*session.history, {"role": "user", "content": [{"text": user_message}]}]

        # First call: the model picks a tool (or just answers). A button offers only its
        # tool, accepts only that tool, and gets one retry if the model doesn't call it.
        only_tool = BUTTON_TOOLS.get(user_message.strip().lower())
        if only_tool:
            agent_span.set_data("empower.button_tool", only_tool)

        def tool_uses(streamed: dict) -> list:
            return [
                b["toolUse"]
                for b in streamed["message"]["content"]
                if "toolUse" in b and (not only_tool or b["toolUse"]["name"] == only_tool)
            ]

        first = _converse_with_fallback(models, messages, capture, only_tool)
        if only_tool and not tool_uses(first):
            sentry_sdk.logger.warning(
                f"Model skipped the {only_tool} button; retrying",
                attributes={"gen_ai.response.finish_reasons": first["stop_reason"] or "unknown"},
            )
            reply = ""
            first = _converse_with_fallback(models, messages, capture, only_tool)
        agent_span.set_data("empower.first_stop_reason", first["stop_reason"] or "unknown")
        if only_tool:
            first["message"]["content"] = [
                b for b in first["message"]["content"] if "toolUse" not in b or b["toolUse"]["name"] == only_tool
            ]
        messages.append(first["message"])
        uses = tool_uses(first)

        if uses:
            # One action per message, as in Empower: run the first tool, skip any others.
            chosen, skipped = uses[0], uses[1:]
            name = chosen["name"]
            emit("status", {"tool": name, "label": STATUS_LABELS.get(name, "Working…"), "agent": agent_ref(TOOL_AGENTS.get(name, ""))})
            result = _run_tool(session, chosen, headers)
            for widget in drain_widgets(session):
                emit("widget", {**widget, "agent": agent_ref(TOOL_AGENTS.get(widget["tool"], ""))})
            emit("agent_end", {"tool": name, "agent": agent_ref(TOOL_AGENTS.get(name, "")), "ran": True})

            messages.append({
                "role": "user",
                "content": [
                    {
                        "toolResult": {
                            "toolUseId": chosen["toolUseId"],
                            "content": [{"json": json.loads(json.dumps(result["payload"], default=str))}],
                            "status": "success" if result["ok"] else "error",
                        }
                    },
                    *[
                        {
                            "toolResult": {
                                "toolUseId": t["toolUseId"],
                                "content": [{"text": "Skipped: only one action runs per customer message."}],
                                "status": "error",
                            }
                        }
                        for t in skipped
                    ],
                ],
            })

            # Second call: the reply. If the model reaches for another tool, it doesn't run.
            second = _converse_with_fallback(models, messages, capture)
            text_only = [b for b in second["message"]["content"] if "text" in b]
            if not text_only:
                fallback = "Done." if result["ok"] else "Sorry, that didn't work."
                capture("token", {"text": fallback})
                capture("message_end", {"agent": agent_ref()})
                text_only = [{"text": fallback}]
            messages.append({"role": "assistant", "content": text_only})
        elif not reply.strip():
            # No tool and no text: never leave the customer with an empty reply.
            sentry_sdk.logger.warning(
                "Model returned neither text nor a tool call",
                attributes={"gen_ai.response.finish_reasons": first["stop_reason"] or "unknown"},
            )
            fallback = "Sorry, I didn't catch that. Could you say it another way?"
            capture("token", {"text": fallback})
            capture("message_end", {"agent": agent_ref()})
            messages[-1] = {"role": "assistant", "content": [{"text": fallback}]}

        session.history = trim_history(messages)
        agent_span.set_data(
            "gen_ai.output.messages",
            json.dumps([{"role": "assistant", "parts": [{"type": "text", "content": reply}]}]),
        )

    emit("pills", {"pills": PILLS.get(session.last_tool or "", PILLS_INITIAL)})
