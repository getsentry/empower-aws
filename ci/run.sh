#!/usr/bin/env bash
# Entry point for GitHub Actions. The workflow only assumes the AWS role and calls this,
# so CI behaviour changes here, not in .github/workflows.
set -euo pipefail
cd "$(dirname "$0")/.."

export AWS_REGION="${AWS_REGION:-us-east-1}"

task_spike() {
  # Public client key for sentry-developer-experience/agent-aws.
  export SENTRY_DSN="https://473b6873169a9cca336b0c725a0a53a5@o4509446862274560.ingest.us.sentry.io/4512387700883456"
  export MODEL_ID="${MODEL_ID:-us.anthropic.claude-sonnet-5-5}"
  aws sts get-caller-identity
  cd spikes/bedrock-sentry
  npm install --no-audit --no-fund
  node --import ./instrument.mjs spike.mjs
}

task_on-push() {
  # Tasks to run on every push to main, one per line. Lines starting with # are skipped.
  while read -r t; do
    [[ -z "$t" || "$t" == \#* ]] && continue
    echo "::group::$t"
    ( "task_$t" )
    echo "::endgroup::"
  done < ci/on-push.txt
}

task="${1:-on-push}"
if ! declare -F "task_$task" >/dev/null; then
  echo "Unknown task: $task" >&2
  exit 1
fi
"task_$task"
