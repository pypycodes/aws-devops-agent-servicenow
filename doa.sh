#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CFN_DIR="$SCRIPT_DIR/cloud-formation"

# Prevent AWS CLI from opening less or prompting interactively.
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# Colours
G='\033[38;5;114m'; Y='\033[38;5;222m'; C='\033[38;5;117m'
R='\033[38;5;210m'; D='\033[38;5;243m'; B='\033[1m'; N='\033[0m'

step() { echo -e "  ${C}▸${N} $1"; }
ok()   { echo -e "  ${G}✔${N} $1"; }
warn() { echo -e "  ${Y}⚠${N} $1"; }
fail() { echo -e "  ${R}✘${N} $1" >&2; exit 1; }

usage() {
  cat <<EOF

  AWS DevOps Agent Demo

  Usage: $0 <command>

  Commands:
    pre          Check prerequisites
    agent-stack  Provision the AWS DevOps Agent stack
    shared-incident     Deploy shared SNS + incident Lambda routing
    deploy-usecase NAME Deploy a use case stack (dynamodb, ec2, eks)
    deploy       Deploy shared incident routing + DynamoDB demo use case
    verify       Verify resources
    servicenow-test     Test ServiceNow OAuth authentication
    servicenow-list     List ServiceNow webhook sys_properties
    servicenow-webhook  Update ServiceNow webhook URL and HMAC secret
    servicenow-verify   Show ServiceNow webhook properties with secret redacted
    trigger      Set DynamoDB max writes to 2 and invoke Lambda
    alarms       Show CloudWatch alarm states
    restore      Remove the DynamoDB maximum write limit
    track        Show CloudFormation stack status and outputs
    cleanup      Delete demo resources
    help         Show this help
EOF
}

trap 'echo -e "\n  ${R}✘${N} Failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

if (( $# == 0 )); then usage; exit 0; fi
case "$1" in
  help|-h|--help) usage; exit 0 ;;
esac

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo -e "\n  ${R}✘${N} .env file not found. Create it first:"
  echo -e "  ${D}cp .env.example .env${N}\n"
  exit 1
fi

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=""
BUCKET=""
STACK_NAME=""
INCIDENT_STACK_NAME=""
DYNAMODB_STACK_NAME=""
EC2_STACK_NAME=""
EKS_STACK_NAME=""
SERVICENOW_WEBHOOK_URL_PROPERTY="aws.devopsagent.webhook.url"
SERVICENOW_WEBHOOK_SECRET_PROPERTY="aws.devopsagent.webhook.secret"

servicenow_incidents_enabled() {
  [[ "${ENABLE_SERVICENOW:-false}" == "true" ]]
}

require_env() {
  local mode="${1:-full}"
  local missing=()

  [[ -n "${ENV:-}" ]] || missing+=(ENV)
  [[ -n "${AWS_PROFILE:-}" ]] || missing+=(AWS_PROFILE)

  if [[ "$mode" != "agent-stack" ]] && ! servicenow_incidents_enabled; then
    [[ -n "${WEBHOOK_URL:-}" ]] || missing+=(WEBHOOK_URL)
    [[ -n "${WEBHOOK_SECRET:-}" ]] || missing+=(WEBHOOK_SECRET)
  fi

  if (( ${#missing[@]} > 0 )); then
    fail "Missing required values in .env: ${missing[*]}"
  fi
}

validate_webhook_config() {
  local secret_fingerprint

  [[ -n "${WEBHOOK_URL:-}" ]] || fail "WEBHOOK_URL is empty in $ENV_FILE"
  [[ "$WEBHOOK_URL" == https://* ]] || fail "WEBHOOK_URL must use HTTPS"
  [[ -n "${WEBHOOK_SECRET:-}" ]] || fail "WEBHOOK_SECRET is empty in $ENV_FILE"

  secret_fingerprint="$(printf '%s' "$WEBHOOK_SECRET" | sha256sum | awk '{print substr($1,1,12)}')"
  echo -e "  ${D}Webhook configuration:${N} $ENV_FILE"
  echo -e "  ${D}Webhook host:${N} ${WEBHOOK_URL%%/webhook/*}/webhook/<redacted>"
  echo -e "  ${D}Secret fingerprint:${N} $secret_fingerprint"
}

validate_servicenow_config() {
  local enabled="${1:-${ENABLE_SERVICENOW:-false}}"
  [[ "$enabled" == "true" ]] || return 0

  validate_servicenow_oauth_config
  [[ -n "${SERVICENOW_INSTANCE_ID:-}" ]] || fail "SERVICENOW_INSTANCE_ID is required"

  echo -e "  ${D}ServiceNow:${N} enabled (${SERVICENOW_INSTANCE_URL})"
}

validate_servicenow_oauth_config() {
  [[ -n "${SERVICENOW_INSTANCE_URL:-}" ]] || fail "SERVICENOW_INSTANCE_URL is required"
  [[ "$SERVICENOW_INSTANCE_URL" =~ ^https://[^/]+\.service-now\.com/?$ ]] || \
    fail "SERVICENOW_INSTANCE_URL must match https://<instance>.service-now.com"
  [[ -n "${SERVICENOW_CLIENT_ID:-}" ]] || fail "SERVICENOW_CLIENT_ID is required"
  [[ -n "${SERVICENOW_CLIENT_SECRET:-}" ]] || fail "SERVICENOW_CLIENT_SECRET is required"
}

require_servicenow_webhook_config() {
  servicenow_incidents_enabled || fail "ENABLE_SERVICENOW must be true to update ServiceNow webhook properties"
  validate_servicenow_oauth_config
  validate_webhook_config
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
}

servicenow_base_url() {
  printf '%s' "${SERVICENOW_INSTANCE_URL%/}"
}

servicenow_access_token() {
  local token_response access_token

  token_response="$(curl --fail-with-body -sS -X POST \
    "$(servicenow_base_url)/oauth_token.do" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${SERVICENOW_CLIENT_ID}" \
    --data-urlencode "client_secret=${SERVICENOW_CLIENT_SECRET}")" || \
    fail "Failed to call ServiceNow OAuth endpoint"

  access_token="$(jq -r '.access_token // empty' <<<"$token_response")"
  [[ -n "$access_token" ]] || fail "ServiceNow OAuth response did not include access_token"
  printf '%s' "$access_token"
}

servicenow_property_sysid() {
  local access_token="$1" property_name="$2"

  curl --fail-with-body -sS --get \
    -H "Authorization: Bearer ${access_token}" \
    -H "Accept: application/json" \
    --data-urlencode "sysparm_query=name=${property_name}" \
    --data-urlencode "sysparm_fields=sys_id,name" \
    --data-urlencode "sysparm_limit=1" \
    "$(servicenow_base_url)/api/now/table/sys_properties" | \
    jq -r '.result[0].sys_id // empty'
}

servicenow_update_property() {
  local access_token="$1" property_name="$2" property_value="$3"
  local sys_id response

  sys_id="$(servicenow_property_sysid "$access_token" "$property_name")"
  [[ -n "$sys_id" ]] || fail "ServiceNow property not found: $property_name"

  response="$(curl --fail-with-body -sS -X PATCH \
    -H "Authorization: Bearer ${access_token}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg value "$property_value" '{value:$value}')" \
    "$(servicenow_base_url)/api/now/table/sys_properties/${sys_id}")" || \
    fail "Failed to update ServiceNow property: $property_name"

  jq -er '.result.sys_id' <<<"$response" >/dev/null || fail "Unexpected update response for $property_name"
  ok "Updated $property_name"
}

servicenow_test() {
  validate_servicenow_oauth_config
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"

  servicenow_access_token >/dev/null
  ok "ServiceNow OAuth authentication successful"
  echo -e "  ${D}Instance:${N} $(servicenow_base_url)"
}

servicenow_list() {
  local access_token
  validate_servicenow_oauth_config
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  access_token="$(servicenow_access_token)"

  curl --fail-with-body -sS --get \
    -H "Authorization: Bearer ${access_token}" \
    -H "Accept: application/json" \
    --data-urlencode "sysparm_query=nameSTARTSWITHaws.devopsagent.webhook" \
    --data-urlencode "sysparm_fields=name,sys_id" \
    "$(servicenow_base_url)/api/now/table/sys_properties" | \
    jq -r '.result[] | "\(.name)  \(.sys_id)"'
}

servicenow_webhook() {
  header "Update ServiceNow Webhook"
  servicenow_update_webhook_properties
}

servicenow_update_webhook_properties() {
  local access_token secret_fingerprint
  require_servicenow_webhook_config
  access_token="$(servicenow_access_token)"

  step "Updating ServiceNow webhook properties"
  servicenow_update_property "$access_token" "$SERVICENOW_WEBHOOK_URL_PROPERTY" "$WEBHOOK_URL"
  servicenow_update_property "$access_token" "$SERVICENOW_WEBHOOK_SECRET_PROPERTY" "$WEBHOOK_SECRET"

  secret_fingerprint="$(printf '%s' "$WEBHOOK_SECRET" | sha256sum | awk '{print substr($1,1,12)}')"
  ok "Webhook URL updated"
  ok "Webhook HMAC secret updated, fingerprint: $secret_fingerprint"
}

stack_owns_resource() {
  local stack_name="$1" logical_id="$2" physical_id="$3" actual_id

  actual_id="$(aws cloudformation describe-stack-resource \
    --stack-name "$stack_name" \
    --logical-resource-id "$logical_id" \
    --region "$REGION" \
    --query 'StackResourceDetail.PhysicalResourceId' \
    --output text --no-cli-pager 2>/dev/null || true)"

  [[ "$actual_id" == "$physical_id" ]]
}

check_log_group_conflict() {
  local stack_name="$1" logical_id="$2" log_group_name="$3" existing_log_group

  existing_log_group="$(aws logs describe-log-groups \
    --log-group-name-prefix "$log_group_name" \
    --region "$REGION" \
    --query "logGroups[?logGroupName=='$log_group_name'].logGroupName | [0]" \
    --output text --no-cli-pager)"

  if [[ "$existing_log_group" != "None" ]] && ! stack_owns_resource "$stack_name" "$logical_id" "$log_group_name"; then
    fail "CloudWatch log group already exists outside stack: $log_group_name. Delete it or choose a new ENV before deploying."
  fi
}

preflight_resource_conflicts() {
  local scope="${1:-all}"
  step "Checking for orphaned CloudWatch log groups"

  if [[ "$scope" == "all" || "$scope" == "dynamodb" ]]; then
    check_log_group_conflict "$DYNAMODB_STACK_NAME" LambdaLogGroup "/aws/lambda/${ENV}-simple-lambda"
  fi

  if [[ "$scope" == "all" || "$scope" == "incident" ]]; then
    if servicenow_incidents_enabled; then
      check_log_group_conflict "$INCIDENT_STACK_NAME" ServiceNowIncidentLogGroup "/aws/lambda/${ENV}-servicenow-incident"
    else
      check_log_group_conflict "$INCIDENT_STACK_NAME" WebhookLogGroup "/aws/lambda/${ENV}-devops-agent-webhook"
    fi
  fi

  ok "No orphaned log group conflicts found"
}

servicenow_verify() {
  local access_token
  validate_servicenow_oauth_config
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  access_token="$(servicenow_access_token)"

  curl --fail-with-body -sS --get \
    -H "Authorization: Bearer ${access_token}" \
    -H "Accept: application/json" \
    --data-urlencode "sysparm_query=nameIN${SERVICENOW_WEBHOOK_URL_PROPERTY},${SERVICENOW_WEBHOOK_SECRET_PROPERTY}" \
    --data-urlencode "sysparm_fields=name,value" \
    "$(servicenow_base_url)/api/now/table/sys_properties" | \
    jq --arg secret_name "$SERVICENOW_WEBHOOK_SECRET_PROPERTY" \
      '.result[] | if .name == $secret_name then .value = "<redacted>" else . end'
}

init() {
  if [[ -z "$ACCOUNT_ID" ]]; then
    ACCOUNT_ID="$(aws sts get-caller-identity --region "$REGION" --query Account --output text --no-cli-pager)" || \
      fail "Unable to read AWS account identity for profile ${AWS_PROFILE:-default}"
    BUCKET="${ENV}-devops-agent-demo-${ACCOUNT_ID}"
    INCIDENT_STACK_NAME="${ENV}-incident-routing"
    DYNAMODB_STACK_NAME="${ENV}-usecase-dynamodb"
    EC2_STACK_NAME="${ENV}-usecase-ec2"
    EKS_STACK_NAME="${ENV}-usecase-eks"
    STACK_NAME="$DYNAMODB_STACK_NAME"
  fi
}

ensure_code_bucket() {
  step "Creating code bucket: $BUCKET"
  if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
    ok "Bucket exists"
  else
    if [[ "$REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --no-cli-pager >/dev/null
    else
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=$REGION" --no-cli-pager >/dev/null
    fi
    ok "Bucket created"
  fi
}

package_lambda_artifacts() {
  local mode="$1" package_dir
  package_dir="$(mktemp -d)"

  case "$mode" in
    incident)
      step "Packaging shared incident Lambda functions"
      if servicenow_incidents_enabled; then
        (cd "$SCRIPT_DIR/lambdas/servicenow-incident" && zip -q -j "$package_dir/servicenow-incident-lambda.zip" index.mjs)
        aws s3 cp "$package_dir/servicenow-incident-lambda.zip" "s3://$BUCKET/servicenow-incident-lambda.zip" --region "$REGION" --quiet
        echo -e "  ${D}Alarm trigger:${N} ServiceNow incident Lambda"
      else
        (cd "$SCRIPT_DIR/lambdas/webhook" && zip -q -j "$package_dir/webhook-lambda.zip" index.mjs)
        aws s3 cp "$package_dir/webhook-lambda.zip" "s3://$BUCKET/webhook-lambda.zip" --region "$REGION" --quiet
        echo -e "  ${D}Alarm trigger:${N} webhook Lambda → DevOps Agent"
      fi
      ;;
    dynamodb)
      step "Packaging DynamoDB use case Lambda function"
      (cd "$SCRIPT_DIR/lambdas/app" && zip -q -j "$package_dir/simple-lambda.zip" simple_lambda.py)
      aws s3 cp "$package_dir/simple-lambda.zip" "s3://$BUCKET/simple-lambda.zip" --region "$REGION" --quiet
      ;;
    *)
      rm -rf "$package_dir"
      fail "Unknown Lambda artifact package mode: $mode"
      ;;
  esac

  rm -rf "$package_dir"
  ok "Lambda packages uploaded"
}

stack_output() {
  local stack_name="$1" output_key="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue | [0]" \
    --output text --no-cli-pager 2>/dev/null || true
}

header() {
  echo -e "\n  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${C}┃${N}  ${B}AWS DevOps Agent Demo${N} - $1"
  echo -e "  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${D}Region:${N} $REGION  ${D}Env:${N} ${ENV:-unset}  ${D}Account:${N} ${ACCOUNT_ID:-unknown}\n"
}

# Run a command with a spinner. The command's output is stored in a temporary log,
# and printed if the command fails. i=$((i+1)) is used because ((i++)) can return
# status 1 on its first run and terminate scripts using set -e.
spin() {
  local msg="$1"; shift
  local log_file pid rc i=0
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

  log_file="$(mktemp)"
  "$@" >"$log_file" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${C}%s${N} %s" "${frames[$((i % ${#frames[@]}))]}" "$msg"
    sleep 0.1
    i=$((i + 1))
  done

  if wait "$pid"; then rc=0; else rc=$?; fi
  printf "\r%*s\r" "$(( ${#msg} + 8 ))" ""

  if (( rc != 0 )); then
    cat "$log_file" >&2
  fi
  rm -f "$log_file"
  return "$rc"
}

pre() {
  header "Prerequisites"
  local passed=0 total=0 tool

  for tool in aws python3 zip jq curl; do
    total=$((total + 1))
    if command -v "$tool" >/dev/null 2>&1; then
      ok "$tool: $(command -v "$tool")"
      passed=$((passed + 1))
    else
      warn "$tool is not installed"
    fi
  done

  total=$((total + 1))
  if python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY
  then
    ok "Python $(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
    passed=$((passed + 1))
  else
    warn "Python 3.11 or newer is required"
  fi

  total=$((total + 1))
  if python3 -c 'import boto3' >/dev/null 2>&1; then
    ok "boto3 available"
    passed=$((passed + 1))
  else
    warn "boto3 is missing: python3 -m pip install boto3"
  fi

  if aws sts get-caller-identity --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    ok "AWS credentials are valid"
  else
    warn "AWS credentials are not available. For SSO run: aws sso login --profile $AWS_PROFILE"
  fi

  echo
  if (( passed == total )); then ok "All $passed/$total prerequisites passed"
  else warn "$passed/$total prerequisites passed"; fi
}

provision_agent_stack() {
  init
  validate_servicenow_config "${ENABLE_SERVICENOW:-false}"
  header "Provision DevOps Agent Stack"

  local agent_stack="CTDevOpsAgentStack"
  local agent_space_name="${ENV}-CTDevOpsAgentSpace"
  local confirm

  echo -e "  ${D}Account:${N} $ACCOUNT_ID"
  echo -e "  ${D}Region:${N} $REGION"
  echo -e "  ${D}Stack:${N} $agent_stack"
  echo -e "  ${D}Agent space:${N} $agent_space_name"
  read -rp "  Proceed? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; return 0; }

  if spin "Provisioning DevOps Agent stack..." \
    aws cloudformation deploy \
      --template-file "$CFN_DIR/devops-agent-stack.yaml" \
      --stack-name "$agent_stack" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        AgentSpaceName="$agent_space_name" \
        AgentSpaceDescription="Agent space deployed with CloudFormation for ${ENV} CT DevOpsAgent Demo" \
        EnableServiceNow="${ENABLE_SERVICENOW:-false}" \
        ServiceNowInstanceUrl="${SERVICENOW_INSTANCE_URL:-}" \
        ServiceNowClientName="${SERVICENOW_CLIENT_NAME:-AWS DevOps Agent ServiceNow Integration}" \
        ServiceNowClientId="${SERVICENOW_CLIENT_ID:-}" \
        ServiceNowClientSecret="${SERVICENOW_CLIENT_SECRET:-}" \
        ServiceNowInstanceId="${SERVICENOW_INSTANCE_ID:-}" \
        NotificationEmail="${NOTIFICATION_EMAIL:-}" \
      --region "$REGION" --no-fail-on-empty-changeset --no-cli-pager; then
    ok "Agent stack provisioned"
  else
    fail "Agent stack deployment failed"
  fi
}

deploy_shared_incident_stack() {
  if servicenow_incidents_enabled; then
    validate_servicenow_config
  else
    validate_webhook_config
  fi
  init
  header "Deploy Shared Incident Routing"

  local confirm agent_topic_arn
  read -rp "  Deploy $INCIDENT_STACK_NAME in account $ACCOUNT_ID? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; return 0; }

  ensure_code_bucket
  if servicenow_incidents_enabled; then
    servicenow_update_webhook_properties
  fi
  package_lambda_artifacts incident

  agent_topic_arn="$(stack_output CTDevOpsAgentStack DevOpsAgentNotificationTopicArn)"
  [[ "$agent_topic_arn" == "None" ]] && agent_topic_arn=""
  preflight_resource_conflicts incident

  if spin "Deploying shared incident routing stack..." \
    aws cloudformation deploy \
      --template-file "$CFN_DIR/shared/incident-routing.yaml" \
      --stack-name "$INCIDENT_STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        Env="$ENV" WebhookUrl="${WEBHOOK_URL:-}" WebhookSecretParam="${WEBHOOK_SECRET:-}" \
        LambdaCodeBucket="$BUCKET" \
        WebhookCodeKey=webhook-lambda.zip \
        ServiceNowIncidentCodeKey=servicenow-incident-lambda.zip \
        EnableServiceNow="${ENABLE_SERVICENOW:-false}" \
        ServiceNowInstanceUrl="${SERVICENOW_INSTANCE_URL:-}" \
        ServiceNowClientId="${SERVICENOW_CLIENT_ID:-}" \
        ServiceNowClientSecret="${SERVICENOW_CLIENT_SECRET:-}" \
        DevOpsAgentNotificationTopicArn="$agent_topic_arn" \
      --region "$REGION" --no-fail-on-empty-changeset --no-cli-pager; then
    ok "Shared incident routing deployed"
  else
    fail "Shared incident routing deployment failed"
  fi
}

ensure_shared_incident_stack() {
  local incident_topic_arn agent_topic_arn

  incident_topic_arn="$(stack_output "$INCIDENT_STACK_NAME" IncidentTopicArn)"
  if [[ -n "$incident_topic_arn" && "$incident_topic_arn" != "None" ]]; then
    ok "Shared incident routing stack exists: $INCIDENT_STACK_NAME"
    return 0
  fi

  step "Shared incident routing stack missing; deploying $INCIDENT_STACK_NAME"
  if servicenow_incidents_enabled; then
    validate_servicenow_config
    servicenow_update_webhook_properties
  else
    validate_webhook_config
  fi

  ensure_code_bucket
  preflight_resource_conflicts incident
  package_lambda_artifacts incident

  agent_topic_arn="$(stack_output CTDevOpsAgentStack DevOpsAgentNotificationTopicArn)"
  [[ "$agent_topic_arn" == "None" ]] && agent_topic_arn=""

  if spin "Deploying shared incident routing stack..." \
    aws cloudformation deploy \
      --template-file "$CFN_DIR/shared/incident-routing.yaml" \
      --stack-name "$INCIDENT_STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        Env="$ENV" WebhookUrl="${WEBHOOK_URL:-}" WebhookSecretParam="${WEBHOOK_SECRET:-}" \
        LambdaCodeBucket="$BUCKET" \
        WebhookCodeKey=webhook-lambda.zip \
        ServiceNowIncidentCodeKey=servicenow-incident-lambda.zip \
        EnableServiceNow="${ENABLE_SERVICENOW:-false}" \
        ServiceNowInstanceUrl="${SERVICENOW_INSTANCE_URL:-}" \
        ServiceNowClientId="${SERVICENOW_CLIENT_ID:-}" \
        ServiceNowClientSecret="${SERVICENOW_CLIENT_SECRET:-}" \
        DevOpsAgentNotificationTopicArn="$agent_topic_arn" \
      --region "$REGION" --no-fail-on-empty-changeset --no-cli-pager; then
    ok "Shared incident routing deployed"
  else
    fail "Shared incident routing deployment failed"
  fi
}

deploy_dynamodb_usecase() {
  init
  header "Deploy DynamoDB Use Case"

  local confirm incident_topic_arn
  read -rp "  Deploy $DYNAMODB_STACK_NAME in account $ACCOUNT_ID? Shared routing will be created if missing. [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; return 0; }

  ensure_shared_incident_stack
  incident_topic_arn="$(stack_output "$INCIDENT_STACK_NAME" IncidentTopicArn)"
  [[ -n "$incident_topic_arn" && "$incident_topic_arn" != "None" ]] || \
    fail "Shared incident routing stack is missing. Run: ./doa.sh shared-incident"

  preflight_resource_conflicts dynamodb
  ensure_code_bucket
  package_lambda_artifacts dynamodb

  if spin "Deploying DynamoDB use case stack..." \
    aws cloudformation deploy \
      --template-file "$CFN_DIR/usecases/dynamodb-simple-lambda.yaml" \
      --stack-name "$DYNAMODB_STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        Env="$ENV" \
        LambdaCodeBucket="$BUCKET" \
        AppCodeKey=simple-lambda.zip \
        IncidentTopicArn="$incident_topic_arn" \
      --region "$REGION" --no-fail-on-empty-changeset --no-cli-pager; then
    ok "DynamoDB use case deployed"
  else
    fail "DynamoDB use case deployment failed"
  fi

  verify
}

deploy_ec2_usecase() {
  init
  header "Deploy EC2 CPU Stress Use Case"

  local confirm incident_topic_arn
  echo -e "  ${D}Instance:${N} t3.nano"
  echo -e "  ${D}Alarm:${N} ${ENV}-EC2-CPU-Spike"
  read -rp "  Deploy $EC2_STACK_NAME in account $ACCOUNT_ID? Shared routing will be created if missing. [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; return 0; }

  ensure_shared_incident_stack
  incident_topic_arn="$(stack_output "$INCIDENT_STACK_NAME" IncidentTopicArn)"
  [[ -n "$incident_topic_arn" && "$incident_topic_arn" != "None" ]] || \
    fail "Shared incident routing stack is missing. Run: ./doa.sh shared-incident"

  if spin "Deploying EC2 CPU stress use case stack..." \
    aws cloudformation deploy \
      --template-file "$CFN_DIR/usecases/ec2-cpu-stress.yaml" \
      --stack-name "$EC2_STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        Env="$ENV" \
        IncidentTopicArn="$incident_topic_arn" \
      --region "$REGION" --no-fail-on-empty-changeset --no-cli-pager; then
    ok "EC2 CPU stress use case deployed"
  else
    fail "EC2 CPU stress use case deployment failed"
  fi
}

deploy_eks_usecase() {
  init
  header "Deploy EKS Node Health Use Case"

  local confirm incident_topic_arn
  echo -e "  ${Y}⚠${N} EKS creates billable control plane and worker node resources. Deployment can take 15-25 minutes."
  echo -e "  ${D}Alarms:${N} ${ENV}-EKS-Node-Memory-High, ${ENV}-EKS-Pod-Restarts, ${ENV}-EKS-Node-NotReady"
  read -rp "  Deploy $EKS_STACK_NAME in account $ACCOUNT_ID? Shared routing will be created if missing. [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; return 0; }

  ensure_shared_incident_stack
  incident_topic_arn="$(stack_output "$INCIDENT_STACK_NAME" IncidentTopicArn)"
  [[ -n "$incident_topic_arn" && "$incident_topic_arn" != "None" ]] || \
    fail "Shared incident routing stack is missing. Run: ./doa.sh shared-incident"

  if spin "Deploying EKS node health use case stack..." \
    aws cloudformation deploy \
      --template-file "$CFN_DIR/usecases/eks-node-health.yaml" \
      --stack-name "$EKS_STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        Env="$ENV" \
        IncidentTopicArn="$incident_topic_arn" \
      --region "$REGION" --no-fail-on-empty-changeset --no-cli-pager; then
    ok "EKS node health use case deployed"
  else
    fail "EKS node health use case deployment failed"
  fi
}

deploy_usecase() {
  local usecase="${1:-dynamodb}"

  case "$usecase" in
    dynamodb|dynamodb-simple-lambda)
      deploy_dynamodb_usecase
      ;;
    ec2|ec2-cpu-stress)
      deploy_ec2_usecase
      ;;
    eks|eks-node-health)
      deploy_eks_usecase
      ;;
    *)
      fail "Unknown use case: $usecase. Available use cases: dynamodb, ec2, eks"
      ;;
  esac
}

deploy() {
  if servicenow_incidents_enabled; then
    validate_servicenow_config
  else
    validate_webhook_config
  fi
  init
  header "Deploy Factory"

  local confirm agent_topic_arn incident_topic_arn
  echo -e "  ${D}Shared stack:${N} $INCIDENT_STACK_NAME"
  echo -e "  ${D}Use case stack:${N} $DYNAMODB_STACK_NAME"
  read -rp "  Deploy shared routing and DynamoDB use case in account $ACCOUNT_ID? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; return 0; }

  ensure_code_bucket
  if servicenow_incidents_enabled; then
    servicenow_update_webhook_properties
  fi
  preflight_resource_conflicts
  package_lambda_artifacts incident

  agent_topic_arn="$(stack_output CTDevOpsAgentStack DevOpsAgentNotificationTopicArn)"
  [[ "$agent_topic_arn" == "None" ]] && agent_topic_arn=""

  if spin "Deploying shared incident routing stack..." \
    aws cloudformation deploy \
      --template-file "$CFN_DIR/shared/incident-routing.yaml" \
      --stack-name "$INCIDENT_STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        Env="$ENV" WebhookUrl="${WEBHOOK_URL:-}" WebhookSecretParam="${WEBHOOK_SECRET:-}" \
        LambdaCodeBucket="$BUCKET" \
        WebhookCodeKey=webhook-lambda.zip \
        ServiceNowIncidentCodeKey=servicenow-incident-lambda.zip \
        EnableServiceNow="${ENABLE_SERVICENOW:-false}" \
        ServiceNowInstanceUrl="${SERVICENOW_INSTANCE_URL:-}" \
        ServiceNowClientId="${SERVICENOW_CLIENT_ID:-}" \
        ServiceNowClientSecret="${SERVICENOW_CLIENT_SECRET:-}" \
        DevOpsAgentNotificationTopicArn="$agent_topic_arn" \
      --region "$REGION" --no-fail-on-empty-changeset --no-cli-pager; then
    ok "Shared incident routing deployed"
  else
    fail "Shared incident routing deployment failed"
  fi

  incident_topic_arn="$(stack_output "$INCIDENT_STACK_NAME" IncidentTopicArn)"
  [[ -n "$incident_topic_arn" && "$incident_topic_arn" != "None" ]] || \
    fail "Shared incident routing stack did not output IncidentTopicArn"

  package_lambda_artifacts dynamodb
  if spin "Deploying DynamoDB use case stack..." \
    aws cloudformation deploy \
      --template-file "$CFN_DIR/usecases/dynamodb-simple-lambda.yaml" \
      --stack-name "$DYNAMODB_STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        Env="$ENV" \
        LambdaCodeBucket="$BUCKET" \
        AppCodeKey=simple-lambda.zip \
        IncidentTopicArn="$incident_topic_arn" \
      --region "$REGION" --no-fail-on-empty-changeset --no-cli-pager; then
    ok "DynamoDB use case deployed"
  else
    fail "DynamoDB use case deployment failed"
  fi

  verify
}

track() {
  init
  header "Stack Status"
  for stack_name in "$INCIDENT_STACK_NAME" "$DYNAMODB_STACK_NAME" "$EC2_STACK_NAME" "$EKS_STACK_NAME"; do
    echo -e "  ${D}Stack:${N} $stack_name"
    aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" \
      --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}' --output json --no-cli-pager 2>/dev/null || \
      warn "Stack not found: $stack_name"
  done
}

verify() {
  init
  header "Resource Verification"
  local passed=0 total=0 sub_count

  check() {
    local label="$1"; shift
    total=$((total + 1))
    if "$@" >/dev/null 2>&1; then ok "$label"; passed=$((passed + 1)); else warn "$label"; fi
  }

  # shellcheck disable=SC2317 # Invoked indirectly via check().
  lambda_absent() {
    ! aws lambda get-function --function-name "$1" --region "$REGION" --no-cli-pager
  }

  check "DynamoDB: ${ENV}-stress-test-table" aws dynamodb describe-table --table-name "${ENV}-stress-test-table" --region "$REGION" --no-cli-pager
  check "S3: ${ENV}-simple-lambda-config-${ACCOUNT_ID}" aws s3api head-bucket --bucket "${ENV}-simple-lambda-config-${ACCOUNT_ID}" --region "$REGION"
  check "Lambda: ${ENV}-simple-lambda" aws lambda get-function --function-name "${ENV}-simple-lambda" --region "$REGION" --no-cli-pager
  check "Log group: /aws/lambda/${ENV}-simple-lambda" aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${ENV}-simple-lambda" --region "$REGION" --query 'logGroups[0].logGroupName' --output text --no-cli-pager
  if servicenow_incidents_enabled; then
    check "Lambda: ${ENV}-servicenow-incident" aws lambda get-function --function-name "${ENV}-servicenow-incident" --region "$REGION" --no-cli-pager
    check "Log group: /aws/lambda/${ENV}-servicenow-incident" aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${ENV}-servicenow-incident" --region "$REGION" --query 'logGroups[0].logGroupName' --output text --no-cli-pager
    check "Webhook Lambda omitted" lambda_absent "${ENV}-devops-agent-webhook"
  else
    check "Lambda: ${ENV}-devops-agent-webhook" aws lambda get-function --function-name "${ENV}-devops-agent-webhook" --region "$REGION" --no-cli-pager
    check "Log group: /aws/lambda/${ENV}-devops-agent-webhook" aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${ENV}-devops-agent-webhook" --region "$REGION" --query 'logGroups[0].logGroupName' --output text --no-cli-pager
    check "Secret: ${ENV}-devops-agent-webhook" aws secretsmanager describe-secret --secret-id "${ENV}-devops-agent-webhook" --region "$REGION" --no-cli-pager
    check "ServiceNow Lambda omitted" lambda_absent "${ENV}-servicenow-incident"
  fi
  check "EventBridge: ${ENV}-simple-lambda-schedule" aws events describe-rule --name "${ENV}-simple-lambda-schedule" --region "$REGION" --no-cli-pager
  check "Alarm: ${ENV}-DynamoDB-WriteThrottle" aws cloudwatch describe-alarms --alarm-names "${ENV}-DynamoDB-WriteThrottle" --region "$REGION" --query 'MetricAlarms[0].AlarmName' --output text --no-cli-pager
  check "Alarm: ${ENV}-Lambda-Errors" aws cloudwatch describe-alarms --alarm-names "${ENV}-Lambda-Errors" --region "$REGION" --query 'MetricAlarms[0].AlarmName' --output text --no-cli-pager

  local topic_arn="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${ENV}-devops-agent-alarms"
  local endpoints
  endpoints="$(aws sns list-subscriptions-by-topic \
    --topic-arn "$topic_arn" \
    --region "$REGION" --query 'Subscriptions[].Endpoint' --output text --no-cli-pager 2>/dev/null || true)"
  sub_count="$(aws sns list-subscriptions-by-topic \
    --topic-arn "$topic_arn" \
    --region "$REGION" --query 'length(Subscriptions)' --output text --no-cli-pager 2>/dev/null || echo 0)"
  check "SNS subscriptions: $sub_count" test "$sub_count" -gt 0
  if servicenow_incidents_enabled; then
    check "Alarm topic → ServiceNow Lambda" grep -q "function:${ENV}-servicenow-incident" <<<"$endpoints"
  else
    check "Alarm topic → webhook Lambda" grep -q "function:${ENV}-devops-agent-webhook" <<<"$endpoints"
  fi

  echo
  if (( passed == total )); then ok "All $passed/$total resources verified"
  else warn "$passed/$total resources verified"; fi
}

# Return: TableStatus, BillingMode, MaxWriteRequestUnits.
get_dynamodb_state() {
  local table_name="$1"
  aws dynamodb describe-table --table-name "$table_name" --region "$REGION" \
    --query 'Table.[TableStatus,BillingModeSummary.BillingMode,OnDemandThroughput.MaxWriteRequestUnits]' \
    --output text --no-cli-pager
}

wait_for_dynamodb_throughput_update() {
  local table_name="$1" expected_limit="$2"
  local max_attempts="${3:-36}" sleep_seconds="${4:-5}"
  local attempt=1 status="UNKNOWN" billing_mode="UNKNOWN" current_limit="UNKNOWN"

  while (( attempt <= max_attempts )); do
    if read -r status billing_mode current_limit < <(get_dynamodb_state "$table_name" 2>/dev/null); then
      :
    else
      status="UNKNOWN"; billing_mode="UNKNOWN"; current_limit="UNKNOWN"
    fi

    if [[ "$expected_limit" == "-1" ]]; then
      if [[ "$status" == "ACTIVE" && "$billing_mode" == "PAY_PER_REQUEST" && \
            ( "$current_limit" == "None" || "$current_limit" == "null" || \
              "$current_limit" == "-1" || -z "$current_limit" ) ]]; then
        printf '\r%*s\r' 120 ''
        ok "DynamoDB write limit removed"
        return 0
      fi
    elif [[ "$status" == "ACTIVE" && "$billing_mode" == "PAY_PER_REQUEST" && \
            "$current_limit" == "$expected_limit" ]]; then
      printf '\r%*s\r' 120 ''
      ok "DynamoDB write limit confirmed: $current_limit"
      return 0
    fi

    printf "\r  ${C}⠿${N} status=%s mode=%s write-limit=%s attempt=%s/%s" \
      "$status" "$billing_mode" "$current_limit" "$attempt" "$max_attempts"
    sleep "$sleep_seconds"
    attempt=$((attempt + 1))
  done

  printf '\r%*s\r' 120 ''
  echo -e "  ${R}✘${N} DynamoDB update did not reach expected state"
  echo -e "  ${D}Table:${N} $table_name"
  echo -e "  ${D}Status:${N} $status"
  echo -e "  ${D}Billing mode:${N} $billing_mode"
  echo -e "  ${D}Current write limit:${N} $current_limit"
  echo -e "  ${D}Expected write limit:${N} $expected_limit"
  return 1
}

update_dynamodb_on_demand_limit() {
  local table_name="$1" max_write_units="$2"

  aws dynamodb update-table --table-name "$table_name" \
    --on-demand-throughput "MaxWriteRequestUnits=$max_write_units" \
    --region "$REGION" --no-cli-pager --output json \
    --query 'TableDescription.[TableName,TableStatus,OnDemandThroughput.MaxWriteRequestUnits]' \
    >/dev/null || return 1

  ok "DynamoDB update request accepted"
  wait_for_dynamodb_throughput_update "$table_name" "$max_write_units"
}

trigger() {
  init
  header "Trigger Incident"
  local table_name="${ENV}-stress-test-table"

  step "Limiting on-demand DynamoDB writes to 2 request units"
  update_dynamodb_on_demand_limit "$table_name" 2 || fail "Failed to set DynamoDB write limit"

  step "Invoking Lambda to generate write throttling"
  if aws lambda invoke --function-name "${ENV}-simple-lambda" --region "$REGION" \
      --cli-connect-timeout 10 --cli-read-timeout 60 --no-cli-pager \
      /tmp/simple-lambda-response.json >/tmp/simple-lambda-invoke.json; then
    ok "Lambda invocation completed"
  else
    fail "Lambda invocation failed"
  fi

  echo -e "  ${D}Alarm:${N} ${ENV}-DynamoDB-WriteThrottle"
  echo -e "  ${D}Restore:${N} ./doa.sh restore"
}

restore() {
  init
  header "Restore"
  local table_name="${ENV}-stress-test-table"

  step "Removing the on-demand DynamoDB write limit"
  update_dynamodb_on_demand_limit "$table_name" -1 || fail "Failed to remove DynamoDB write limit"
  ok "DynamoDB remains PAY_PER_REQUEST with no explicit write limit"
}

alarms() {
  init
  header "Alarm Status"
  aws cloudwatch describe-alarms \
    --alarm-names "${ENV}-DynamoDB-WriteThrottle" "${ENV}-Lambda-Errors" \
    --query 'MetricAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp]' \
    --output table --region "$REGION" --no-cli-pager
}

cleanup() {
  init
  header "Cleanup"
  local config_bucket="${ENV}-simple-lambda-config-${ACCOUNT_ID}"
  local agent_stack="CTDevOpsAgentStack"
  local confirm

  echo -e "  ${R}${B}This deletes:${N} $EKS_STACK_NAME, $EC2_STACK_NAME, $DYNAMODB_STACK_NAME, $INCIDENT_STACK_NAME, $agent_stack, $config_bucket and $BUCKET"
  read -rp "  Proceed with cleanup? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; return 0; }

  aws events disable-rule --name "${ENV}-simple-lambda-schedule" --region "$REGION" --no-cli-pager 2>/dev/null || true

  for bucket in "$config_bucket" "$BUCKET"; do
    if aws s3api head-bucket --bucket "$bucket" --region "$REGION" >/dev/null 2>&1; then
      aws s3 rm "s3://$bucket" --recursive --quiet --region "$REGION" || true
      aws s3 rb "s3://$bucket" --force --region "$REGION" >/dev/null 2>&1 || true
    fi
  done

  if aws cloudformation describe-stacks --stack-name "$EKS_STACK_NAME" --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "$EKS_STACK_NAME" --region "$REGION" --no-cli-pager
    spin "Deleting EKS use case stack..." aws cloudformation wait stack-delete-complete --stack-name "$EKS_STACK_NAME" --region "$REGION" --no-cli-pager || \
      warn "EKS use case stack deletion did not complete cleanly"
  fi

  if aws cloudformation describe-stacks --stack-name "$EC2_STACK_NAME" --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "$EC2_STACK_NAME" --region "$REGION" --no-cli-pager
    spin "Deleting EC2 use case stack..." aws cloudformation wait stack-delete-complete --stack-name "$EC2_STACK_NAME" --region "$REGION" --no-cli-pager || \
      warn "EC2 use case stack deletion did not complete cleanly"
  fi

  if aws cloudformation describe-stacks --stack-name "$DYNAMODB_STACK_NAME" --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "$DYNAMODB_STACK_NAME" --region "$REGION" --no-cli-pager
    spin "Deleting DynamoDB use case stack..." aws cloudformation wait stack-delete-complete --stack-name "$DYNAMODB_STACK_NAME" --region "$REGION" --no-cli-pager || \
      warn "DynamoDB use case stack deletion did not complete cleanly"
  fi

  if aws cloudformation describe-stacks --stack-name "$INCIDENT_STACK_NAME" --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "$INCIDENT_STACK_NAME" --region "$REGION" --no-cli-pager
    spin "Deleting shared incident routing stack..." aws cloudformation wait stack-delete-complete --stack-name "$INCIDENT_STACK_NAME" --region "$REGION" --no-cli-pager || \
      warn "Shared incident routing stack deletion did not complete cleanly"
  fi

  if aws cloudformation describe-stacks --stack-name "$agent_stack" --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "$agent_stack" --region "$REGION" --no-cli-pager
    spin "Deleting agent stack..." aws cloudformation wait stack-delete-complete --stack-name "$agent_stack" --region "$REGION" --no-cli-pager || \
      warn "Agent stack deletion did not complete cleanly"
  fi

  ok "Cleanup completed"
}

command="$1"
shift

case "$command" in
  pre) pre ;;
  help|-h|--help) usage ;;
  servicenow-test) servicenow_test ;;
  servicenow-list) servicenow_list ;;
  servicenow-webhook|servicenow-update-webhook) servicenow_webhook ;;
  servicenow-verify|servicenow-verify-webhook) servicenow_verify ;;
  agent-stack|provision-agent-stack)
    require_env agent-stack
    provision_agent_stack
    ;;
  shared-incident|incident-routing)
    require_env
    deploy_shared_incident_stack
    ;;
  deploy-usecase)
    require_env
    deploy_usecase "$@"
    ;;
  deploy|trigger|restore|track|verify|cleanup|alarms)
    require_env
    "$command"
    ;;
  *)
    echo -e "  ${R}Unknown command:${N} $command"
    usage
    exit 1
    ;;
esac
