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
  # Both us. and global. profiles passed a 10-call check; earlier 503s were temporary.
  export MODEL_ID="${MODEL_ID:-global.anthropic.claude-sonnet-5-5}"
  (cd spikes/bedrock-sentry && npm install --no-audit --no-fund --loglevel=error)
  use_bedrock_role
  cd spikes/bedrock-sentry
  node --import ./instrument.mjs spike.mjs
}

task_probe() {
  (cd spikes/bedrock-sentry && npm install --no-audit --no-fund --loglevel=error)
  use_bedrock_role
  node spikes/bedrock-sentry/probe.mjs
}

TF_VERSION="1.17.1"
tf() { terraform -chdir=infra "$@"; }

install_terraform() {
  if ! terraform version 2>/dev/null | grep -q "v${TF_VERSION}"; then
    curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" -o /tmp/tf.zip
    mkdir -p "$HOME/bin" && unzip -o -q /tmp/tf.zip -d "$HOME/bin"
    export PATH="$HOME/bin:$PATH"
  fi
  terraform version | head -1
}

tf_init() {
  local account bucket
  account="$(aws sts get-caller-identity --query Account --output text)"
  bucket="empower-aws-tfstate-${account}"
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    aws s3api create-bucket --bucket "$bucket" >/dev/null
    aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
    aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    echo "Created state bucket ${bucket}."
  fi
  tf init -input=false -no-color -backend-config="bucket=${bucket}" >/dev/null
  tf validate -no-color
}

build_and_push() {
  local tag="$1" registry
  registry="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
  aws ecr get-login-password | docker login --username AWS --password-stdin "$registry" >/dev/null
  for pair in agent:services/agent store:services/store seed:db traffic:services/traffic; do
    local name="${pair%%:*}" dir="${pair#*:}"
    docker build --quiet -t "${registry}/empower-aws/${name}:${tag}" "$dir" >/dev/null
    docker push --quiet "${registry}/empower-aws/${name}:${tag}" >/dev/null
    echo "Pushed ${name}:${tag}"
  done
}

# A bad collector config would stop the whole ECS task (every container is essential),
# so check it with the same collector image before deploying.
validate_collector() {
  local image config
  image="$(grep -o 'ghcr.io/open-telemetry/[^"]*' infra/main.tf | head -1)"
  config="$(sed -e 's#${otlp_base}#https://example.invalid/api/1/integration/otlp#' \
    -e 's#${sentry_key}#placeholder#' \
    -e 's#${rds_log_group}#/aws/rds/instance/empower-aws/postgresql#g' \
    -e 's#${ecs_log_group}#/empower-aws/ecs#g' infra/collector.yaml)"
  docker run --rm -e OTEL_CONFIG="$config" "$image" validate --config=env:OTEL_CONFIG
  echo "Collector config is valid."
}

seed_database() {
  local task status code
  task="$(aws ecs run-task --cluster "$(tf output -raw cluster)" --launch-type FARGATE \
    --task-definition "$(tf output -raw seed_task_definition)" \
    --network-configuration "awsvpcConfiguration={subnets=[$(tf output -raw public_subnets)],securityGroups=[$(tf output -raw task_security_group)],assignPublicIp=ENABLED}" \
    --query 'tasks[0].taskArn' --output text)"
  aws ecs wait tasks-stopped --cluster "$(tf output -raw cluster)" --tasks "$task"
  code="$(aws ecs describe-tasks --cluster "$(tf output -raw cluster)" --tasks "$task" --query 'tasks[0].containers[0].exitCode' --output text)"
  aws logs get-log-events --log-group-name /empower-aws/ecs --log-stream-name "app/seed/${task##*/}" \
    --query 'events[].message' --output text 2>/dev/null | tail -5 || true
  [[ "$code" == "0" ]] || { echo "Seed task failed (exit ${code})."; return 1; }
}

publish_storefront() {
  local tag="$1"
  (
    cd services/storefront
    npm ci --no-audit --no-fund --loglevel=error
    export SENTRY_ORG=sentry-developer-experience REACT_SENTRY_PROJECT=frontend-aws
    envsubst '${SENTRY_ORG} ${REACT_SENTRY_PROJECT}' < config-overrides.js.template > config-overrides.js
    # CI is unset so Create React App doesn't turn lint warnings into errors.
    env -u CI \
      REACT_APP_DSN="https://9988cd868e2720af66c5b816105af760@o4509446862274560.ingest.us.sentry.io/4512387700817920" \
      REACT_APP_RELEASE="$tag" \
      REACT_APP_ENVIRONMENT="aws-demo" \
      REACT_APP_BACKEND_URL_FLASK="/store" \
      REACT_APP_BACKEND_URL_FLASKOTLP="/store" \
      REACT_APP_BACKEND_URL_AGENT="/agent" \
      npm run build >/tmp/storefront-build.log 2>&1 || { tail -40 /tmp/storefront-build.log; exit 1; }
  )
  local bucket; bucket="$(tf output -raw storefront_bucket)"
  aws s3 sync services/storefront/build "s3://${bucket}" --delete --only-show-errors
  aws s3 cp services/storefront/build/index.html "s3://${bucket}/index.html" --cache-control no-cache --only-show-errors
  aws cloudfront create-invalidation --distribution-id "$(tf output -raw distribution_id)" --paths '/*' >/dev/null
  echo "Published storefront ${tag}."
}

smoke_test() {
  local url; url="$(tf output -raw url)"
  echo "Storefront: ${url}"
  echo "Custom domain certificate: $(tf output -raw custom_domain_status)"
  tf output -json custom_domain_dns | python3 -c 'import json,sys; [print("  dns", r) for r in json.load(sys.stdin)]'
  echo "url=${url}" >> "${CI_SUMMARY:-/tmp/ci-summary}"
  for attempt in $(seq 1 30); do
    if curl -fsS -o /dev/null "${url}/agent/health" && curl -fsS -o /dev/null "${url}/store/success"; then break; fi
    echo "Waiting for ${url} (attempt ${attempt})..."; sleep 20
  done
  echo "products: $(curl -fsS "${url}/store/products" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') items"
  local conv="ci-${GITHUB_RUN_ID:-local}"
  for message in "Show me plants under \$200" "Add one of each to the cart" "Checkout" "Apply Coupon" "Purchase"; do
    echo "--- ${message}"
    curl -sS -N --max-time 120 -X POST "${url}/agent/api/v1/chat" -H 'content-type: application/json' \
      -H "x-conversation-id: ${conv}" -d "{\"message\": \"${message}\"}" \
      | python3 -c '
import json, sys
event = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("event: "): event = line[7:]
    elif line.startswith("data: ") and event not in ("token",):
        data = json.loads(line[6:])
        if event == "widget": print("  widget", data.get("type"), "ok" if (data.get("data") or {}).get("ok", True) else "FAILED")
        elif event in ("status", "error", "done", "pills"): print(" ", event, json.dumps(data)[:160])'
  done
}

task_deploy() {
  local tag; tag="$(git rev-parse --short=12 HEAD)"
  validate_collector
  install_terraform
  tf_init
  tf apply -input=false -auto-approve -no-color -target=aws_ecr_repository.repo -target=aws_ecr_lifecycle_policy.repo | tail -2
  build_and_push "$tag"
  if ! tf apply -input=false -auto-approve -no-color -var "image_tag=${tag}" >/tmp/apply.log 2>&1; then
    grep -E "Error|│" /tmp/apply.log | head -60
    return 1
  fi
  grep "Apply complete" /tmp/apply.log
  seed_database
  publish_storefront "$tag"
  aws ecs wait services-stable --cluster "$(tf output -raw cluster)" --services "$(tf output -raw service)"
  smoke_test
  traffic_check "$tag"
}

# One run of every traffic flow in a real browser, using the image the traffic service runs.
traffic_check() {
  local registry
  registry="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
  docker run --rm --ipc=host -e STOREFRONT_URL="$(tf output -raw url)" \
    "${registry}/empower-aws/traffic:$1" node traffic.mjs --once
}

# Where the custom domain stands: DNS records as public resolvers see them, and the certificate.
task_domain() {
  local domain="reinvent.sentry.dev" arn
  for name in "$domain" "_faf6f563f977cc6efae388598ec54a64.${domain}"; do
    echo "dns ${name} -> $(dig +short CNAME "$name" @8.8.8.8 | tr '\n' ' ')"
  done
  for name in "$domain" sentry.dev; do
    echo "caa ${name} -> $(dig +short CAA "$name" @8.8.8.8 | tr '\n' ' ')"
  done
  for arn in $(aws acm list-certificates --includes keyTypes=RSA_2048 \
      --certificate-statuses PENDING_VALIDATION ISSUED FAILED VALIDATION_TIMED_OUT \
      --query "CertificateSummaryList[?DomainName=='${domain}'].CertificateArn" --output text); do
    echo "certificate ${arn##*/} $(aws acm describe-certificate --certificate-arn "$arn" \
      --query 'Certificate.[Status, FailureReason, DomainValidationOptions[0].ValidationStatus, CreatedAt]' --output text)"
  done
  curl -sS -o /dev/null -w "https://${domain} -> %{http_code}\n" "https://${domain}/" || true
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
