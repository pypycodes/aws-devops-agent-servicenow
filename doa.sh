#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
G='\033[38;5;114m' Y='\033[38;5;222m' C='\033[38;5;117m' R='\033[38;5;210m' D='\033[38;5;243m' B='\033[1m' N='\033[0m'

# Load .env if present
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
else
  echo -e "\n  ${R}✘${N} .env file not found. Create one from the template:"
  echo -e "  ${D}    cp .env.example .env${N}"
  echo -e "  ${D}    # Then edit .env with your values${N}\n"
  exit 1
fi

REGION="${AWS_REGION:-us-east-1}"

# Require ENV to be set (except for pre and help)
# Require all .env values to be set
require_env() {
  local missing=()
  [[ -z "${ENV:-}" ]] && missing+=("ENV")
  [[ -z "${AWS_PROFILE:-}" ]] && missing+=("AWS_PROFILE")
  [[ -z "${WEBHOOK_URL:-}" ]] && missing+=("WEBHOOK_URL")
  [[ -z "${WEBHOOK_SECRET:-}" ]] && missing+=("WEBHOOK_SECRET")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "  ${R}✘${N} Missing required values in .env: ${missing[*]}"
    exit 1
  fi
}

# Lazy-load account ID (only when needed)
init() {
  if [[ -z "${ACCOUNT_ID:-}" ]]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    BUCKET="${ENV}-devops-agent-demo-${ACCOUNT_ID}"
  fi
}

header() {
  echo -e "\n  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${C}┃${N}  ${B}AWS DevOps Agent Demo${N} — $1"
  echo -e "  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${D}Region:${N} $REGION  ${D}Env:${N} $ENV  ${D}Account:${N} ${ACCOUNT_ID:-unknown}\n"
}

step() { echo -e "  ${C}▸${N} $1"; }
ok()   { echo -e "  ${G}✔${N} $1"; }
fail() { echo -e "  ${R}✘${N} $1"; exit 1; }
warn() { echo -e "  ${Y}⚠${N} $1"; }

# Run a command with a spinner animation
spin() {
  local msg="$1"; shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  "$@" &>/dev/null &
  local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${C}${frames[$((i % ${#frames[@]}))]}${N} %s" "$msg"
    sleep 0.1
    ((i++))
  done
  wait "$pid"
  local rc=$?
  printf "\r%*s\r" $((${#msg} + 6)) ""
  return $rc
}

# ── PRE: Prerequisites Check ──
pre() {
  echo -e "\n  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "  ${C}┃${N}  ${B}AWS DevOps Agent Demo${N} — Prerequisites"
  echo -e "  ${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}\n"

  PASS=0; TOTAL=0
  MISSING=()

  # Generic: check command, prompt to install if missing
  ensure() {
    local tool="$1" install_cmd="$2" link="$3"
    TOTAL=$((TOTAL + 1))
    if command -v "$tool" &>/dev/null; then
      ok "$tool $(command -v "$tool")"; PASS=$((PASS + 1)); return
    fi
    echo -e "  ${Y}⚠${N} $tool not found"
    [[ -n "$link" ]] && echo -e "  ${D}  Install guide: $link${N}"
    read -rp "  Install $tool now? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      step "Installing $tool..."
      if eval "$install_cmd"; then ok "$tool installed"; PASS=$((PASS + 1))
      else echo -e "  ${R}✘${N} Failed to install $tool"; fi
    else
      echo -e "  ${R}✘${N} $tool required"
    fi
  }

  # For tools that should not be auto-installed (e.g. python3 — tzdata prompt issues)
  ensure_manual() {
    local tool="$1" link="$2"
    TOTAL=$((TOTAL + 1))
    if command -v "$tool" &>/dev/null; then
      ok "$tool $(command -v "$tool")"; PASS=$((PASS + 1)); return
    fi
    echo -e "  ${R}✘${N} $tool not found — install manually: $link"
    MISSING+=("$tool")
  }

  # Package manager install helper
  pkg() {
    local SUDO=""; command -v sudo &>/dev/null && SUDO="sudo"
    if command -v brew &>/dev/null; then brew install "$1"
    elif command -v apt-get &>/dev/null; then export DEBIAN_FRONTEND=noninteractive; ${SUDO:+$SUDO -E} apt-get update && ${SUDO:+$SUDO -E} apt-get install -y "$1"
    elif command -v yum &>/dev/null; then $SUDO yum install -y "$1"
    elif command -v dnf &>/dev/null; then $SUDO dnf install -y "$1"
    else return 1; fi
  }

  # AWS CLI install (cross-platform)
  install_awscli() {
    local SUDO=""; command -v sudo &>/dev/null && SUDO="sudo"
    if [[ "$(uname)" == "Darwin" ]]; then
      curl -sL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg && $SUDO installer -pkg /tmp/AWSCLIV2.pkg -target /
    else
      $SUDO apt-get update -qq 2>/dev/null; $SUDO apt-get install -y -qq curl unzip 2>/dev/null || true
      curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
        && unzip -qo /tmp/awscliv2.zip -d /tmp && $SUDO /tmp/aws/install && rm -rf /tmp/aws /tmp/awscliv2.zip
    fi
  }

  step "Checking required tools..."
  ensure aws     "install_awscli" "https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
  ensure_manual python3          "https://www.python.org/downloads/"
  ensure zip     "pkg zip"       "https://linux.die.net/man/1/zip"
  ensure jq      "pkg jq"        "https://jqlang.org/download/"

  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${R}Missing: ${MISSING[*]}${N}"
    echo -e "  ${D}Install and re-run: ./doa.sh pre${N}"
    exit 1
  fi

  # Python version
  TOTAL=$((TOTAL + 1))
  PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
  if [[ "${PY_VER%%.*}" -ge 3 && "${PY_VER##*.}" -ge 11 ]]; then
    ok "Python $PY_VER"; PASS=$((PASS + 1))
  else
    echo -e "  ${R}✘${N} Python $PY_VER — need 3.11+ (https://www.python.org/downloads/)"
  fi

  # boto3
  TOTAL=$((TOTAL + 1))
  if python3 -c "import boto3" &>/dev/null; then
    ok "boto3 available"; PASS=$((PASS + 1))
  else
    echo -e "  ${Y}⚠${N} boto3 not found"
    read -rp "  Install boto3 now? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      step "Installing boto3..."
      if pkg python3-boto3 2>/dev/null || pip3 install --break-system-packages boto3 2>/dev/null || pip3 install boto3 2>/dev/null; then
        ok "boto3 installed"; PASS=$((PASS + 1))
      else
        echo -e "  ${R}✘${N} Failed — run manually: pip3 install boto3"
      fi
    else
      echo -e "  ${R}✘${N} boto3 required — run: pip3 install boto3"
    fi
  fi

  echo ""
  if [[ $PASS -eq $TOTAL ]]; then
    ok "${G}All ${PASS}/${TOTAL} tools installed${N}"
  else
    warn "${Y}${PASS}/${TOTAL} tools installed${N}"
  fi

  # ── Next Steps (not counted in pass/total) ──
  echo -e "\n  ${B}Next steps:${N}"

  if aws sts get-caller-identity &>/dev/null; then
    ok "AWS credentials configured"
  else
    echo -e "  ${Y}☐${N} Configure AWS credentials:"
    echo -e "  ${D}    aws configure${N}"
    echo -e "  ${D}    # Enter your AWS Access Key ID, Secret Access Key, and default region (us-east-1)${N}"
  fi

  SPACES=$(aws devops-agent list-agent-spaces --region "$REGION" --output json 2>/dev/null || echo '{"agentSpaces":[]}')
  SPACE_COUNT=$(echo "$SPACES" | jq '.agentSpaces | length')
  if [[ "$SPACE_COUNT" -gt 0 ]]; then
    ok "$SPACE_COUNT agent space(s) found"
  else
    echo -e "  ${Y}☐${N} Create a AWS DevOps Agent space:"
    echo -e "  ${D}    https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html${N}"
  fi

  if [[ -n "${WEBHOOK_URL:-}" && -n "${WEBHOOK_SECRET:-}" ]]; then
    ok "WEBHOOK_URL and WEBHOOK_SECRET set"
  else
    echo -e "  ${Y}☐${N} Set webhook credentials:"
    echo -e "  ${D}    export WEBHOOK_URL=https://...${N}"
    echo -e "  ${D}    export WEBHOOK_SECRET=your-secret${N}"
  fi

  echo -e "\n  ${B}Ready to deploy? Run:${N}"
  echo -e "  ${D}    export ENV=dev${N}"
  echo -e "  ${D}    export AWS_REGION=us-east-1${N}"
  echo -e "  ${D}    ./doa.sh deploy    # Sets up DynamoDB, Lambda, EventBridge, SNS, CloudWatch Alarms${N}"
  echo ""
}

# ── DEPLOY: Infrastructure ──
deploy() {
  init
  header "Deploy Infrastructure"

  # Show deployment summary
  AGENT_SPACE=$(aws devops-agent list-agent-spaces --region "$REGION" --query 'agentSpaces[0].{id:agentSpaceId,name:name}' --output text 2>/dev/null || echo "none")
  echo -e "  ${B}Deployment Target${N}"
  echo -e "  ${D}├─${N} Account:     $ACCOUNT_ID"
  echo -e "  ${D}├─${N} Region:      $REGION"
  echo -e "  ${D}├─${N} Agent Space: $AGENT_SPACE"
  echo -e "  ${D}└─${N} Stack:       $STACK_NAME"
  echo
  read -rp "  Proceed? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo -e "  ${D}Aborted.${N}"; exit 0; }

  step "Creating code bucket: $BUCKET"
  aws s3 mb "s3://$BUCKET" --region "$REGION" 2>/dev/null && ok "Bucket created" || ok "Bucket exists"

  step "Packaging app Lambda..."
  (cd "$SCRIPT_DIR/lambdas/app" && zip -q /tmp/simple-lambda.zip simple_lambda.py)
  aws s3 cp /tmp/simple-lambda.zip "s3://$BUCKET/simple-lambda.zip" --quiet
  ok "simple-lambda.zip uploaded"

  step "Packaging webhook Lambda..."
  (cd "$SCRIPT_DIR/lambdas/webhook" && zip -q /tmp/webhook-lambda.zip index.mjs)
  aws s3 cp /tmp/webhook-lambda.zip "s3://$BUCKET/webhook-lambda.zip" --quiet
  ok "webhook-lambda.zip uploaded"

  step "Deploying CloudFormation stack..."
  if spin "Deploying stack (this takes ~2 min)..." \
    aws cloudformation deploy \
      --template-file "$SCRIPT_DIR/template.yaml" \
      --stack-name "$STACK_NAME" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        Env="$ENV" \
        WebhookUrl="$WEBHOOK_URL" \
        WebhookSecretParam="$WEBHOOK_SECRET" \
        LambdaCodeBucket="$BUCKET" \
        AppCodeKey=simple-lambda.zip \
        WebhookCodeKey=webhook-lambda.zip \
      --region "$REGION" \
      --no-fail-on-empty-changeset; then
    ok "Stack deployed"
  else
    fail "Stack deployment failed. Run: aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $REGION"
  fi

  track
  verify

  echo -e "  ${B}Next step — start the monitor and inject the fault:${N}"
  echo -e "  ${D}    python3 scripts/agent_monitor.py   # Terminal 1: watch investigations${N}"
  echo -e "  ${D}    ./doa.sh trigger                   # Terminal 2: inject DynamoDB throttling${N}"
  echo ""
}

# ── TRACK ──
track() {
  init
  header "Stack Progress"

  STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$STATUS" == *"IN_PROGRESS"* ]]; then
    step "Stack is ${Y}${STATUS}${N} — watching events..."
    echo ""
    aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION" 2>/dev/null &
    WAIT_PID=$!

    SEEN=""
    while kill -0 $WAIT_PID 2>/dev/null; do
      EVENTS=$(aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --region "$REGION" \
        --query "StackEvents[?ResourceStatus!='CREATE_IN_PROGRESS'].[Timestamp,LogicalResourceId,ResourceStatus]" \
        --output text 2>/dev/null | head -20)
      while IFS=$'\t' read -r ts resource status; do
        KEY="${resource}:${status}"
        if [[ ! "$SEEN" == *"$KEY"* ]]; then
          SEEN="$SEEN $KEY"
          case "$status" in
            *COMPLETE)   ok "${D}${ts}${N}  ${resource} → ${G}${status}${N}" ;;
            *FAILED)     fail "${D}${ts}${N}  ${resource} → ${R}${status}${N}" ;;
            *ROLLBACK*)  warn "${D}${ts}${N}  ${resource} → ${Y}${status}${N}" ;;
          esac
        fi
      done <<< "$EVENTS"
      sleep 5
    done
    echo ""
  fi

  STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "NOT_FOUND")

  case "$STATUS" in
    *COMPLETE)    ok "Stack status: ${G}${STATUS}${N}" ;;
    *FAILED|*ROLLBACK*) fail "Stack status: ${R}${STATUS}${N}" ;;
    NOT_FOUND)    warn "Stack not found" ;;
    *)            step "Stack status: ${Y}${STATUS}${N}" ;;
  esac

  echo ""
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output table 2>/dev/null || true
}

# ── VERIFY ──
verify() {
  init
  header "Resource Verification"

  PASS=0; TOTAL=0

  check() {
    TOTAL=$((TOTAL + 1))
    local label="$1"; shift
    if "$@" &>/dev/null; then
      ok "$label"; PASS=$((PASS + 1))
    else
      echo -e "  ${R}✘${N} $label"
    fi
  }

  check "DynamoDB table: ${ENV}-stress-test-table" \
    aws dynamodb describe-table --table-name "${ENV}-stress-test-table" --region "$REGION"

  check "S3 bucket: ${ENV}-simple-lambda-config-${ACCOUNT_ID}" \
    aws s3api head-bucket --bucket "${ENV}-simple-lambda-config-${ACCOUNT_ID}" --region "$REGION"

  check "Lambda: ${ENV}-simple-lambda" \
    aws lambda get-function --function-name "${ENV}-simple-lambda" --region "$REGION"

  check "Lambda: ${ENV}-devops-agent-webhook" \
    aws lambda get-function --function-name "${ENV}-devops-agent-webhook" --region "$REGION"

  check "EventBridge: ${ENV}-simple-lambda-schedule" \
    aws events describe-rule --name "${ENV}-simple-lambda-schedule" --region "$REGION"

  check "SNS topic: ${ENV}-devops-agent-alarms" \
    aws sns get-topic-attributes --topic-arn "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${ENV}-devops-agent-alarms" --region "$REGION"

  check "Secret: ${ENV}-devops-agent-webhook" \
    aws secretsmanager describe-secret --secret-id "${ENV}-devops-agent-webhook" --region "$REGION"

  check "Alarm: ${ENV}-DynamoDB-WriteThrottle" \
    aws cloudwatch describe-alarms --alarm-names "${ENV}-DynamoDB-WriteThrottle" --region "$REGION" \
    --query "MetricAlarms[0].AlarmName" --output text

  check "Alarm: ${ENV}-Lambda-Errors" \
    aws cloudwatch describe-alarms --alarm-names "${ENV}-Lambda-Errors" --region "$REGION" \
    --query "MetricAlarms[0].AlarmName" --output text

  SUB_COUNT=$(aws sns list-subscriptions-by-topic \
    --topic-arn "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${ENV}-devops-agent-alarms" \
    --region "$REGION" --query "length(Subscriptions)" --output text 2>/dev/null || echo "0")
  check "SNS → Lambda subscription (${SUB_COUNT})" \
    test "$SUB_COUNT" -gt 0

  check "Log group: /aws/lambda/${ENV}-simple-lambda" \
    aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${ENV}-simple-lambda" \
    --region "$REGION" --query "logGroups[0].logGroupName" --output text

  check "Log group: /aws/lambda/${ENV}-devops-agent-webhook" \
    aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/${ENV}-devops-agent-webhook" \
    --region "$REGION" --query "logGroups[0].logGroupName" --output text

  echo ""
  if [[ $PASS -eq $TOTAL ]]; then
    ok "${G}All ${PASS}/${TOTAL} resources verified${N}"
  else
    warn "${Y}${PASS}/${TOTAL} resources verified${N}"
  fi
  echo ""
}

# ── TRIGGER ──
trigger() {
  init
  header "Trigger Incident"

  step "Injecting fault: switching DynamoDB to provisioned (2 WCU)..."
  aws dynamodb update-table \
    --table-name "${ENV}-stress-test-table" \
    --billing-mode PROVISIONED \
    --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=2 \
    --region "$REGION" &>/dev/null
  ok "Table now at 2 WCU — throttling will start on next Lambda invocation"

  step "Invoking Lambda immediately to start throttling..."
  aws lambda invoke --function-name "${ENV}-simple-lambda" --region "$REGION" /dev/null &>/dev/null &
  ok "Lambda invoked — alarm should fire within ~1 minute"
  echo -e "  ${D}Alarm:${N} ${ENV}-DynamoDB-WriteThrottle"
  echo ""
  echo -e "  ${B}Next step — once investigation completes, restore normal operation:${N}"
  echo -e "  ${D}    ./doa.sh restore${N}"
  echo ""
}

# ── RESTORE ──
restore() {
  init
  header "Restore"

  step "Restoring DynamoDB to on-demand..."
  aws dynamodb update-table \
    --table-name "${ENV}-stress-test-table" \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" &>/dev/null
  ok "Table restored to on-demand — throttling will stop"
  echo ""
  echo -e "  ${B}Next step — clean up all resources when done:${N}"
  echo -e "  ${D}    ./doa.sh cleanup${N}"
  echo ""
}

# ── ALARMS ──
alarms() {
  init
  header "Alarm Status"

  aws cloudwatch describe-alarms \
    --alarm-names "${ENV}-DynamoDB-WriteThrottle" "${ENV}-Lambda-Errors" \
    --query "MetricAlarms[].[AlarmName,StateValue,StateUpdatedTimestamp]" \
    --output table --region "$REGION"
}

# ── CLEANUP ──
cleanup() {
  init
  header "Cleanup"

  CONFIG_BUCKET="${ENV}-simple-lambda-config-${ACCOUNT_ID}"

  # Show cleanup summary
  echo -e "  ${R}${B}⚠ This will permanently delete:${N}"
  echo -e "  ${D}├─${N} Account:  $ACCOUNT_ID"
  echo -e "  ${D}├─${N} Region:   $REGION"
  echo -e "  ${D}├─${N} Stack:    $STACK_NAME"
  echo -e "  ${D}├─${N} Bucket:   $CONFIG_BUCKET"
  echo -e "  ${D}├─${N} Bucket:   $BUCKET"
  echo -e "  ${D}└─${N} Logs:     /aws/lambda/${ENV}-simple-lambda, /aws/lambda/${ENV}-devops-agent-webhook"
  echo
  read -rp "  Proceed with cleanup? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo -e "  ${D}Aborted.${N}"; exit 0; }

  step "Disabling EventBridge schedule..."
  aws events disable-rule --name "${ENV}-simple-lambda-schedule" --region "$REGION" 2>/dev/null || true
  ok "Schedule disabled"

  step "Emptying config bucket: $CONFIG_BUCKET"
  if aws s3api head-bucket --bucket "$CONFIG_BUCKET" --region "$REGION" 2>/dev/null; then
    aws s3 rm "s3://$CONFIG_BUCKET" --recursive --quiet --region "$REGION" 2>/dev/null || true
    # Purge delete markers and old versions left from when versioning was enabled
    VERSIONS=$(aws s3api list-object-versions --bucket "$CONFIG_BUCKET" --region "$REGION" --output json 2>/dev/null || echo '{}')
    DELETE_PAYLOAD=$(echo "$VERSIONS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
objects = [{'Key': o['Key'], 'VersionId': o['VersionId']}
           for o in data.get('Versions', []) + data.get('DeleteMarkers', [])]
if objects:
    print(json.dumps({'Objects': objects, 'Quiet': True}))
" 2>/dev/null || true)
    if [[ -n "$DELETE_PAYLOAD" ]]; then
      aws s3api delete-objects --bucket "$CONFIG_BUCKET" --region "$REGION" --delete "$DELETE_PAYLOAD" 2>/dev/null || true
    fi
  fi
  ok "Bucket emptied"

  step "Deleting stack: $STACK_NAME"
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  if spin "Waiting for stack deletion..." \
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"; then
    ok "Stack deleted"
  else
    warn "Stack deletion may still be in progress"
  fi

  step "Cleaning up orphaned log groups..."
  for lg in "/aws/lambda/${ENV}-simple-lambda" "/aws/lambda/${ENV}-devops-agent-webhook"; do
    aws logs delete-log-group --log-group-name "$lg" --region "$REGION" 2>/dev/null && \
      ok "Deleted $lg" || true
  done

  step "Removing S3 bucket: $BUCKET"
  aws s3 rb "s3://$BUCKET" --force --region "$REGION" 2>/dev/null && \
    ok "Bucket removed" || warn "Bucket may not exist"

  ok "Cleanup complete"
  echo ""
  echo -e "  ${B}All resources removed. To redeploy:${N}"
  echo -e "  ${D}    ./doa.sh deploy${N}"
  echo ""
}

# ── USAGE ──
usage() {
  echo -e "\n  ${B}AWS DevOps Agent Demo${N} — Automated Incident Lifecycle\n"
  echo -e "  ${B}Usage:${N} $0 <command>\n"
  echo -e "  ${B}Setup:${N}"
  echo -e "    cp .env.example .env    ${D}# configure account, region, webhook creds${N}\n"
  echo -e "  ${B}Commands:${N}"
  echo -e "    ${C}pre${N}        Check prerequisites (CLI tools, credentials, agent space)"
  echo -e "    ${C}deploy${N}     Deploy infrastructure (DynamoDB, Lambda, SNS, Alarms)"
  echo -e "    ${C}verify${N}     Verify all resources exist and are healthy"
  echo -e "    ${C}trigger${N}    Inject fault — switch DynamoDB to 2 WCU provisioned"
  echo -e "    ${C}alarms${N}     Check CloudWatch alarm states"
  echo -e "    ${C}restore${N}    Undo fault — restore DynamoDB to on-demand"
  echo -e "    ${C}track${N}      Watch CloudFormation stack events"
  echo -e "    ${C}cleanup${N}    Tear down all resources (with confirmation)\n"
  echo -e "  ${B}Quick start:${N}"
  echo -e "    ${D}1.${N} cp .env.example .env       ${D}# configure${N}"
  echo -e "    ${D}2.${N} $0 pre                     ${D}# check tools & creds${N}"
  echo -e "    ${D}3.${N} $0 deploy                  ${D}# deploy infra${N}"
  echo -e "    ${D}4.${N} source .env && python3 scripts/agent_monitor.py  ${D}# terminal 2${N}"
  echo -e "    ${D}5.${N} $0 trigger                 ${D}# inject incident${N}"
  echo -e "    ${D}6.${N} $0 restore                 ${D}# undo fault${N}"
  echo -e "    ${D}7.${N} $0 cleanup                 ${D}# tear down${N}\n"
}

# ── MAIN ──
if [[ $# -eq 0 ]]; then
  usage; exit 0
fi

CMD="$1"

case "$CMD" in
  pre)     pre ;;
  help|-h) usage ;;
  deploy|trigger|restore|track|verify|cleanup|alarms)
    require_env
    STACK_NAME="${ENV}-devops-agent-demo"
    $CMD ;;
  *)       echo -e "  ${R}Unknown command: $CMD${N}"; usage; exit 1 ;;
esac
