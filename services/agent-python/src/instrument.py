"""Sentry setup for the Python agent. Imported first by server.py.

The boto3 integration (on by default, Bedrock support since sentry-sdk 2.75.0) creates a
gen_ai.chat span for every Bedrock Converse/ConverseStream call, with the model, tokens,
finish reason and, with send_default_pii, the prompt and reply. The agent and tool spans
are added by hand in agent.py, as in the TypeScript agent.
"""
import os

import sentry_sdk

CONVERSATION_TAG = "conversation_id"


def _stamp_conversation(event, hint):
    # sentry_sdk.ai.set_conversation_id() stores the ID on the scope, but the Bedrock
    # integration doesn't copy it onto its spans (only the OpenAI integrations do), so
    # Explore -> Agents couldn't group a chat's turns. Stamp it onto every gen_ai span.
    conversation_id = (event.get("tags") or {}).get(CONVERSATION_TAG)
    if conversation_id:
        for span in event.get("spans") or []:
            if str(span.get("op", "")).startswith("gen_ai."):
                span.setdefault("data", {})["gen_ai.conversation.id"] = conversation_id
    return event


sentry_sdk.init(
    dsn=os.environ.get("SENTRY_DSN"),
    environment=os.environ.get("SENTRY_ENVIRONMENT", "aws-demo"),
    release=os.environ.get("SENTRY_RELEASE"),
    traces_sample_rate=1.0,
    enable_logs=True,
    # Prompts and replies on the Bedrock spans. The demo has no real customer data.
    send_default_pii=True,
    # Trace headers go to the store API next to us, never to AWS.
    trace_propagation_targets=[r"^https?://(localhost|127\.0\.0\.1)(:\d+)?/"],
    before_send_transaction=_stamp_conversation,
)
