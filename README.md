# Empower on AWS

The re:Invent 2026 demo: Empower Plant's storefront and store API on AWS, with a TypeScript
shopping agent on Amazon Bedrock, traced end to end in Sentry (`sentry-developer-experience`).

| Path | What it is |
| --- | --- |
| `services/agent` | TypeScript agent (Node 22, `@sentry/node`, AWS SDK for Bedrock). Same chat API as Empower's Python agent |
| `services/store` | Empower's `flask-otlp` store API, patched for RDS, an OTel Collector and sqlcommenter |
| `services/storefront` | Empower's React storefront, patched so Statsig is optional |
| `db` | Empower's catalogue and a one-off seed image |
| `infra` | Terraform: VPC, RDS, ECS Fargate, ALB, CloudFront, S3, IAM |
| `ci` | Everything CI runs. `.github/workflows/ci.yml` only assumes the AWS role and calls `ci/run.sh` |
| `bootstrap` | One-time admin setup for the AWS deploy role, and a read-only account report |
| `spikes` | The Bedrock and Sentry checks that preceded the build |

`services/store`, `services/storefront` and `db` are copied from
[sentry-demos/empower](https://github.com/sentry-demos/empower) at `9ae02c7`; changes are
marked with `empower-aws:` comments.

Every push to `main` deploys (`ci/on-push.txt`) and reports the result to the `ci-aws`
Sentry project. Shut everything down after re:Invent with `terraform destroy` in `infra`.

## Sentry code mappings (suspect commits)

Suspect commits and source links come from the getsentry GitHub integration in
`sentry-developer-experience`, through these code mappings (Settings → Integrations →
GitHub → Code Mappings). Sentry had generated wrong ones automatically from file names;
these replace them:

| Project | Stack trace root | Source root in getsentry/empower-aws |
|---|---|---|
| backend-flask-otlp-aws | `src/` | `services/store/src/` |
| agent-aws | `/app/` | `services/agent/` |
| agent-python-aws | `/app/` | `services/agent-python/` |

Suspect commits are worked out when an event arrives, so events from before a mapping
change show none.

## Two agents: TypeScript (default) and Python

The chat runs on the TypeScript agent (`services/agent`, Sentry JavaScript SDK) unless the
page is opened with `?agent=python`, which sends it to the Python agent
(`services/agent-python`, Sentry Python SDK 2.75+, Sentry project `agent-python-aws`). The
choice is remembered for the tab, like `?se=`. Both have the same tools, prompt and SSE
contract, and both trace into the same store API.

- `/agent/*` → TypeScript agent (port 8000); `/agent-py/*` → Python agent (port 8001).
- Bedrock spans come from each SDK's AWS integration; the `invoke_agent` and
  `execute_tool` spans are added by hand in both.
- Python notes: the agent is ASGI (Starlette), because Sentry's WSGI middleware ends the
  transaction before a streamed response is sent. SDK 2.75 sends gen_ai spans as separate
  span items next to the transaction. `set_conversation_id` isn't copied onto the Bedrock
  spans by the SDK yet, so the agent stamps `gen_ai.conversation.id` in
  `before_send_transaction`.
- Scheduled traffic picks one agent per session; CI's smoke test and `reliability` task run
  both.
