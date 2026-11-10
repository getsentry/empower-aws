#!/usr/bin/env bash
# Read-only snapshot of the AWS account for sizing the demo: spend, budgets, what already
# runs in us-east-1, and the quotas the demo depends on. Creates and changes nothing.
#
# Run in AWS CloudShell:
#   curl -fsSLO https://raw.githubusercontent.com/getsentry/empower-aws/main/bootstrap/account-report.sh
#   bash account-report.sh
# Sections your role can't read print an AccessDenied line; that's fine.
set -uo pipefail
R=us-east-1
section() { echo; echo "## $*"; }
q() { "$@" 2>&1 | head -60; }
first_of_month=$(date -u +%Y-%m-01)
tomorrow=$(date -u -d tomorrow +%F)

section "Identity"
q aws sts get-caller-identity --query Arn --output text

section "Spend by month, last 4 months (unblended, USD)"
q aws ce get-cost-and-usage --time-period Start=$(date -u -d "$first_of_month -3 months" +%F),End=$tomorrow \
  --granularity MONTHLY --metrics UnblendedCost \
  --query 'ResultsByTime[].[TimePeriod.Start,Total.UnblendedCost.Amount]' --output text

top_services() {
  echo "-- $1 to $2"
  aws ce get-cost-and-usage --time-period Start=$1,End=$2 --granularity MONTHLY --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE --output json 2>&1 | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    groups = json.loads(raw)["ResultsByTime"][0]["Groups"]
except Exception:
    print(raw.strip()[:300]); sys.exit()
for g in sorted(groups, key=lambda g: -float(g["Metrics"]["UnblendedCost"]["Amount"]))[:12]:
    print("%10.2f  %s" % (float(g["Metrics"]["UnblendedCost"]["Amount"]), g["Keys"][0]))'
}
section "Top services, last month and this month"
top_services "$(date -u -d "$first_of_month -1 month" +%F)" "$first_of_month"
top_services "$first_of_month" "$tomorrow"

section "Forecast for the rest of this month"
q aws ce get-cost-forecast --time-period Start=$tomorrow,End=$(date -u -d "$first_of_month +1 month" +%F) \
  --metric UNBLENDED_COST --granularity MONTHLY --query 'Total.Amount' --output text

section "Budgets"
q aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount,TimeUnit]' --output text

section "What already runs in $R"
count() { printf '%-16s %s\n' "$1" "$("${@:2}" --region $R --output text 2>&1 | head -1)"; }
count "VPCs"           aws ec2 describe-vpcs --query 'length(Vpcs)'
count "NAT gateways"   aws ec2 describe-nat-gateways --filter Name=state,Values=available --query 'length(NatGateways)'
count "Elastic IPs"    aws ec2 describe-addresses --query 'length(Addresses)'
count "EC2 running"    aws ec2 describe-instances --filters Name=instance-state-name,Values=running --query 'length(Reservations[].Instances[])'
count "ECS clusters"   aws ecs list-clusters --query 'length(clusterArns)'
count "RDS instances"  aws rds describe-db-instances --query 'length(DBInstances)'
count "Load balancers" aws elbv2 describe-load-balancers --query 'length(LoadBalancers)'
count "ECR repos"      aws ecr describe-repositories --query 'length(repositories)'
printf '%-16s %s\n' "CloudFront" "$(aws cloudfront list-distributions --query 'DistributionList.Quantity' --output text 2>&1 | head -1)"

section "Running EC2 by type and name"
q aws ec2 describe-instances --region $R --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[InstanceType,Tags[?Key==`Name`]|[0].Value]' --output text
section "RDS instances"
q aws rds describe-db-instances --region $R --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,Engine,MultiAZ]' --output text

section "Quotas the demo depends on ($R)"
quota() { printf '%-42s %s\n' "$2" "$(aws service-quotas get-service-quota --region $R --service-code "$1" --quota-code "$3" --query 'Quota.Value' --output text 2>&1 | head -1)"; }
quota vpc "VPCs per Region" L-F678F1CE
quota ec2 "Elastic IPs" L-0263D0A3
quota fargate "Fargate On-Demand vCPU" L-3032A538
quota elasticloadbalancing "Application Load Balancers per Region" L-53DA6B97

section "Bedrock quotas for Claude 5.5 models"
aws service-quotas list-service-quotas --region $R --service-code bedrock --output json 2>&1 | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    quotas = json.loads(raw)["Quotas"]
except Exception:
    print(raw.strip()[:300]); sys.exit()
for x in quotas:
    if "5.5" in x["QuotaName"] and "Claude" in x["QuotaName"]:
        print("%14s  %s" % (x["Value"], x["QuotaName"]))'
