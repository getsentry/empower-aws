#!/usr/bin/env bash
# Empower on AWS: one-time admin setup for the re:Invent demo.
#
# Creates, in the current AWS account:
#   1. The GitHub Actions OIDC identity provider, if it doesn't exist yet.
#   2. A permissions boundary, empower-aws-boundary, that caps every role the demo creates.
#   3. A deploy role, github-empower-aws-deploy, that only the demo repo's GitHub Actions can assume.
#
# The deploy role gets PowerUserAccess (no IAM, no Organizations), limited to us-east-1,
# plus IAM rights only for roles named empower-aws-* that carry the boundary above.
# Those roles can call Bedrock, write logs, pull images and read secrets. Nothing else.
#
# Run in AWS CloudShell as an account admin:  bash empower-aws-admin-setup.sh
# Safe to run again: existing resources are updated, not duplicated.
# To undo, run with --delete.

set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-getsentry/empower-aws}"   # owner/name of the demo repo
REGION="us-east-1"
ROLE_NAME="github-empower-aws-deploy"
BOUNDARY_NAME="empower-aws-boundary"
APP_ROLE_PREFIX="empower-aws-"
OIDC_HOST="token.actions.githubusercontent.com"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER="$(aws sts get-caller-identity --query Arn --output text)"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
BOUNDARY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${BOUNDARY_NAME}"
APP_ROLES_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${APP_ROLE_PREFIX}*"
WORK="$(mktemp -d)"

if [[ "${1:-}" == "--delete" ]]; then
  echo "Deleting ${ROLE_NAME} and ${BOUNDARY_NAME} from account ${ACCOUNT_ID}."
  echo "Delete any empower-aws-* roles first; the demo's Terraform destroy does that."
  read -r -p "Continue? (y/N) " ok; [[ "$ok" == [yY] ]] || exit 1
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name empower-aws-deploy || true
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/PowerUserAccess || true
  aws iam delete-role --role-name "$ROLE_NAME" || true
  for v in $(aws iam list-policy-versions --policy-arn "$BOUNDARY_ARN" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null); do
    [[ "$v" == "None" ]] || aws iam delete-policy-version --policy-arn "$BOUNDARY_ARN" --version-id "$v" || true
  done
  aws iam delete-policy --policy-arn "$BOUNDARY_ARN" || true
  echo "Done. The GitHub OIDC provider was left in place, since other repos may use it."
  exit 0
fi

# GitHub repos created after July 15, 2026 identify as repo:OWNER@OWNER_ID/NAME@REPO_ID.
# Pin the IDs when the repo is public; otherwise match the names with any ID.
OWNER="${GITHUB_REPO%%/*}"
NAME="${GITHUB_REPO##*/}"
github_id() {
  curl -fsS -m 10 "https://api.github.com/$1" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || echo '*'
}
OWNER_ID="$(github_id "users/${OWNER}")"
REPO_ID="$(github_id "repos/${GITHUB_REPO}")"
SUB_ID_FORMAT="repo:${OWNER}@${OWNER_ID}/${NAME}@${REPO_ID}:*"
SUB_NAME_FORMAT="repo:${GITHUB_REPO}:*"

cat <<EOF

Account:     ${ACCOUNT_ID}
Running as:  ${CALLER}
GitHub repo: ${GITHUB_REPO}  (owner ID ${OWNER_ID}, repo ID ${REPO_ID})
Region:      ${REGION}

This creates:
  - OIDC provider ${OIDC_HOST} (skipped if it exists)
  - Policy ${BOUNDARY_NAME}
  - Role ${ROLE_NAME}: PowerUserAccess in ${REGION}, plus IAM limited to
    ${APP_ROLE_PREFIX}* roles that carry ${BOUNDARY_NAME}
EOF
if [[ "$REPO_ID" == '*' ]]; then
  echo
  echo "Note: repo ${GITHUB_REPO} isn't public or doesn't exist yet, so the trust policy"
  echo "matches it by name. Run this again once it's public to pin its ID."
fi
echo
read -r -p "Continue? (y/N) " ok; [[ "$ok" == [yY] ]] || exit 1

# 1. GitHub OIDC provider
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "OIDC provider already exists."
else
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" --client-id-list sts.amazonaws.com >/dev/null
  echo "Created OIDC provider."
fi

# 2. Boundary: the most any demo-created role can ever do
cat >"$WORK/boundary.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DemoWorkloads",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:FilterLogEvents",
        "logs:GetLogEvents",
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "secretsmanager:GetSecretValue",
        "ssm:GetParameters",
        "kms:Decrypt",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
EOF
if aws iam get-policy --policy-arn "$BOUNDARY_ARN" >/dev/null 2>&1; then
  # Keep at most 5 versions: drop the oldest non-default one before adding a new one.
  OLD="$(aws iam list-policy-versions --policy-arn "$BOUNDARY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text | awk '{print $NF}')"
  if [[ -n "$OLD" && "$OLD" != "None" ]]; then
    aws iam delete-policy-version --policy-arn "$BOUNDARY_ARN" --version-id "$OLD"
  fi
  aws iam create-policy-version --policy-arn "$BOUNDARY_ARN" \
    --policy-document "file://$WORK/boundary.json" --set-as-default >/dev/null
  echo "Updated ${BOUNDARY_NAME}."
else
  aws iam create-policy --policy-name "$BOUNDARY_NAME" \
    --description "Caps roles created by the Empower on AWS demo" \
    --policy-document "file://$WORK/boundary.json" >/dev/null
  echo "Created ${BOUNDARY_NAME}."
fi

# 3. Deploy role, assumable only from the demo repo's GitHub Actions
cat >"$WORK/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "${OIDC_HOST}:aud": "sts.amazonaws.com" },
        "StringLike": { "${OIDC_HOST}:sub": ["${SUB_ID_FORMAT}", "${SUB_NAME_FORMAT}"] }
      }
    }
  ]
}
EOF
cat >"$WORK/deploy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CreateDemoRolesOnlyWithBoundary",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:PutRolePermissionsBoundary",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy"
      ],
      "Resource": "${APP_ROLES_ARN}",
      "Condition": { "StringEquals": { "iam:PermissionsBoundary": "${BOUNDARY_ARN}" } }
    },
    {
      "Sid": "ManageDemoRoles",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:DeleteRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRoleTags",
        "iam:UpdateRole",
        "iam:UpdateRoleDescription",
        "iam:UpdateAssumeRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole"
      ],
      "Resource": "${APP_ROLES_ARN}"
    },
    {
      "Sid": "PassDemoRolesToEcsOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "${APP_ROLES_ARN}",
      "Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } }
    },
    {
      "Sid": "ReadPolicies",
      "Effect": "Allow",
      "Action": ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"],
      "Resource": "*"
    },
    {
      "Sid": "StayInOneRegion",
      "Effect": "Deny",
      "NotAction": [
        "iam:*", "sts:*", "cloudfront:*", "route53:*", "budgets:*",
        "support:*", "organizations:*", "account:*", "ce:*", "health:*"
      ],
      "Resource": "*",
      "Condition": { "StringNotEquals": { "aws:RequestedRegion": "${REGION}" } }
    }
  ]
}
EOF

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "file://$WORK/trust.json"
  echo "Updated trust policy on ${ROLE_NAME}."
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "GitHub Actions deploy role for the Empower on AWS demo (${GITHUB_REPO})" \
    --assume-role-policy-document "file://$WORK/trust.json" \
    --max-session-duration 7200 \
    --tags Key=project,Value=empower-aws Key=repo,Value="${GITHUB_REPO}" >/dev/null
  echo "Created ${ROLE_NAME}."
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name empower-aws-deploy \
  --policy-document "file://$WORK/deploy.json"

echo
echo "Done. Send this role ARN back:"
aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text
