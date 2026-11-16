"""Sentry setup for the Python agent. Imported first by server.py.

The boto3 integration (on by default, Bedrock support since sentry-sdk 2.75.0) creates a
gen_ai.chat span for every Bedrock Converse/ConverseStream call, with the model, tokens,
cached tokens, cost and finish reason. The agent and tool spans are added by hand in
agent.py, as in the TypeScript agent.

Privacy story: data_collection keeps what customers type out of Sentry (gen_ai inputs off)
but keeps the model's replies (outputs on). Tokens, cost and cache usage are recorded
either way. (send_default_pii is deprecated and ignored once data_collection is set.)
"""
import os

import sentry_sdk

sentry_sdk.init(
    dsn=os.environ.get("SENTRY_DSN"),
    environment=os.environ.get("SENTRY_ENVIRONMENT", "aws-demo"),
    release=os.environ.get("SENTRY_RELEASE"),
    traces_sample_rate=1.0,
    enable_logs=True,
    # What customers say stays out of Sentry; how the model answers is kept.
    data_collection={"gen_ai": {"inputs": False, "outputs": True}},
    # Trace headers go to the store API next to us, never to AWS.
    trace_propagation_targets=[r"^https?://(localhost|127\.0\.0\.1)(:\d+)?/"],
)
