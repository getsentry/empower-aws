"""HTTP server for the chat widget: the same contract as the TypeScript agent's server.ts.

POST {prefix}/api/v1/chat with x-conversation-id, answered as a Server-Sent Events stream
of status, token, message_end, agent_end, widget, pills, error and done events. Behind
CloudFront this agent lives under /agent-py, so both /agent-py/... and /... are served.

Starlette (ASGI), not Flask (WSGI): Sentry's WSGI middleware ends the request's
transaction when the response object is returned, before a streamed response is sent, so
the Bedrock and tool spans would be lost. The ASGI middleware ends it after the stream.
"""
from . import instrument  # noqa: F401  (Sentry first)

import asyncio
import contextvars
import json
import os

import sentry_sdk
import sentry_sdk.ai
import uvicorn
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware
from starlette.responses import JSONResponse, StreamingResponse
from starlette.routing import Route

from .agent import run_turn
from .session import get_session
from .tools import DEMO_HEADERS

HEALTH = {"status": "healthy", "agent_name": "Shopping Agent", "version": "1.0.0", "sdk": "sentry-python"}


def _header(request, name: str) -> str | None:
    value = request.headers.get(name)
    return value if value and value != "undefined" else None


async def health(request):
    return JSONResponse(HEALTH)


async def chat(request):
    conversation_id = _header(request, "x-conversation-id")
    if not conversation_id:
        return JSONResponse({"detail": "x-conversation-id is required"}, status_code=400)
    try:
        body = await request.json()
    except ValueError:
        body = {}
    message = str(body.get("message") or "").strip()
    if not message:
        return JSONResponse({"detail": "message is required"}, status_code=400)

    # The SDK copies this onto every gen_ai span when it finishes, Bedrock's included.
    sentry_sdk.ai.set_conversation_id(conversation_id)
    headers = {name: v for name in DEMO_HEADERS if (v := _header(request, name))}
    for name in ("se", "customerType", "cexp"):
        if name in headers:
            sentry_sdk.set_tag(name, headers[name])
    model_key = "haiku" if request.query_params.get("model") == "haiku" else "sonnet"
    sentry_sdk.set_tag("agent.model", model_key)
    sentry_sdk.set_tag("agent.sdk", "python")

    loop = asyncio.get_running_loop()
    queue: asyncio.Queue = asyncio.Queue()

    def emit(event: str, data: dict) -> None:
        loop.call_soon_threadsafe(queue.put_nowait, (event, data))

    def work() -> None:
        # Runs in one worker thread, in a copy of this request's context, so every span the
        # turn creates (boto3's Bedrock spans included) lands in the request's transaction.
        session = get_session(conversation_id)
        try:
            with session.lock:
                run_turn(session, message, headers, model_key, emit)
        except Exception as error:  # noqa: BLE001 - headers are sent; report in-band
            sentry_sdk.capture_exception(error)
            emit("widget", {"type": "error", "data": {"message": str(error)}})
            emit("error", {"code": "turn_failed", "message": str(error)})
        finally:
            emit("done", {"conversation_id": conversation_id})
            loop.call_soon_threadsafe(queue.put_nowait, None)

    context = contextvars.copy_context()
    loop.run_in_executor(None, context.run, work)

    async def stream():
        while True:
            try:
                item = await asyncio.wait_for(queue.get(), timeout=10)
            except asyncio.TimeoutError:
                # Keeps CloudFront and the load balancer from timing out a slow turn.
                yield ": ping\n\n"
                continue
            if item is None:
                return
            event, data = item
            yield f"event: {event}\ndata: {json.dumps(data, default=str)}\n\n"

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


routes = []
for prefix in ("/agent-py", ""):
    routes += [
        Route(f"{prefix}/health", health),
        Route(f"{prefix}/api/v1/health", health),
        Route(f"{prefix}/api/v1/chat", chat, methods=["POST"]),
    ]

app = Starlette(
    routes=routes,
    middleware=[Middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])],
)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8001")), log_level="info")
