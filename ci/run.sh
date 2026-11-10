#!/usr/bin/env bash
# Entry point for GitHub Actions. The workflow only assumes the AWS role and calls this,
# so CI behaviour changes here, not in .github/workflows.
# Every run's result and log tail is also sent to Sentry (ci-aws) by ci/report.py.
set -euo pipefail
cd "$(dirname "$0")/.."

export AWS_REGION="${AWS_REGION:-us-east-1}"
BOUNDARY_POLICY="empower-aws-boundary"

# Bedrock calls run under a role the deploy role creates, not the deploy role itself.
# The deploy role is limited to us-east-1, and us.* inference profiles route calls to
# us-east-1, us-east-2 and us-west-2. The ECS tasks will use roles like this one.
use_bedrock_role() {
  local name="empower-aws-ci-bedrock"
  local account deploy_role
  account="$(aws sts get-caller-identity --query Account --output text)"
  deploy_role="arn:aws:iam::${account}:role/github-empower-aws-deploy"

  if ! aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    aws iam create-role --role-name "$name" \
      --description "Bedrock calls from empower-aws CI" \
      --permissions-boundary "arn:aws:iam::${account}:policy/${BOUNDARY_POLICY}" \
      --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"${deploy_role}\"},\"Action\":\"sts:AssumeRole\"}]}" \
      >/dev/null
    echo "Created role ${name}."
  fi
  aws iam put-role-policy --role-name "$name" --policy-name bedrock-invoke \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream"],"Resource":"*"}]}'

  # New roles can take a few seconds to become assumable.
  local creds=""
  for attempt in 1 2 3 4 5 6 7 8; do
    if creds="$(aws sts assume-role --role-arn "arn:aws:iam::${account}:role/${name}" \
        --role-session-name "ci-${GITHUB_RUN_ID:-local}" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null)"; then
      break
    fi
    echo "Waiting for ${name} to become assumable (attempt ${attempt})..."
    sleep 5
  done
  [[ -n "$creds" ]] || { echo "Could not assume ${name}" >&2; return 1; }
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$creds"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  aws sts get-caller-identity --query Arn --output text
}

task_spike() {
  # Public client key for sentry-developer-experience/agent-aws.
  export SENTRY_DSN="https://473b6873169a9cca336b0c725a0a53a5@o4509446862274560.ingest.us.sentry.io/4512387700883456"
  # global.* routes to any region with capacity; us.* kept failing with ServiceUnavailableException.
  export MODEL_ID="${MODEL_ID:-global.anthropic.claude-sonnet-5-5}"
  (cd spikes/bedrock-sentry && npm install --no-audit --no-fund --loglevel=error)
  use_bedrock_role
  cd spikes/bedrock-sentry
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

log="$(mktemp)"
set +e
( set -euo pipefail; "task_$task" ) 2>&1 | tee "$log"
code=${PIPESTATUS[0]}
set -e
python3 ci/report.py "$task" "$code" "$log" || true
exit "$code"
