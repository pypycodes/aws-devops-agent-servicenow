#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"

WEBHOOK_URL_PROPERTY="aws.devopsagent.webhook.url"
WEBHOOK_SECRET_PROPERTY="aws.devopsagent.webhook.secret"

usage() {
  cat <<EOF

  ServiceNow helper

  Usage: $0 <command>

  Commands:
    test             Test ServiceNow OAuth authentication
    list-properties  List aws.devopsagent.webhook sys_properties
    update-webhook   Update webhook URL and HMAC secret from .env
    verify-webhook   Show webhook property values, with secret redacted
    help             Show this help
EOF
}

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

load_env() {
  [[ -f "$ENV_FILE" ]] || fail ".env file not found at $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

require_tools() {
  command -v curl >/dev/null 2>&1 || fail "curl is required"
  command -v jq >/dev/null 2>&1 || fail "jq is required"
}

require_servicenow_env() {
  [[ -n "${SERVICENOW_INSTANCE_URL:-}" ]] || fail "SERVICENOW_INSTANCE_URL is required"
  [[ -n "${SERVICENOW_CLIENT_ID:-}" ]] || fail "SERVICENOW_CLIENT_ID is required"
  [[ -n "${SERVICENOW_CLIENT_SECRET:-}" ]] || fail "SERVICENOW_CLIENT_SECRET is required"
}

require_webhook_env() {
  [[ -n "${WEBHOOK_URL:-}" ]] || fail "WEBHOOK_URL is required"
  [[ "$WEBHOOK_URL" == https://* ]] || fail "WEBHOOK_URL must use HTTPS"
  [[ -n "${WEBHOOK_SECRET:-}" ]] || fail "WEBHOOK_SECRET is required"
}

servicenow_base_url() {
  printf '%s' "${SERVICENOW_INSTANCE_URL%/}"
}

get_access_token() {
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

get_property_sysid() {
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

update_property() {
  local access_token="$1" property_name="$2" property_value="$3"
  local sys_id response

  sys_id="$(get_property_sysid "$access_token" "$property_name")"
  [[ -n "$sys_id" ]] || fail "Property not found: $property_name"

  response="$(curl --fail-with-body -sS -X PATCH \
    -H "Authorization: Bearer ${access_token}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg value "$property_value" '{value:$value}')" \
    "$(servicenow_base_url)/api/now/table/sys_properties/${sys_id}")" || \
    fail "Failed to update property: $property_name"

  jq -er '.result.sys_id' <<<"$response" >/dev/null || fail "Unexpected update response for $property_name"
  echo "Updated $property_name"
}

test_oauth() {
  local access_token
  access_token="$(get_access_token)"
  [[ -n "$access_token" ]] || fail "OAuth authentication failed"
  echo "OAuth authentication successful"
  echo "Instance: $(servicenow_base_url)"
}

list_properties() {
  local access_token
  access_token="$(get_access_token)"

  curl --fail-with-body -sS --get \
    -H "Authorization: Bearer ${access_token}" \
    -H "Accept: application/json" \
    --data-urlencode "sysparm_query=nameSTARTSWITHaws.devopsagent.webhook" \
    --data-urlencode "sysparm_fields=name,sys_id" \
    "$(servicenow_base_url)/api/now/table/sys_properties" | \
    jq -r '.result[] | "\(.name)  \(.sys_id)"'
}

update_webhook() {
  local access_token secret_fingerprint
  require_webhook_env
  access_token="$(get_access_token)"

  echo "Updating ServiceNow webhook properties..."
  update_property "$access_token" "$WEBHOOK_URL_PROPERTY" "$WEBHOOK_URL"
  update_property "$access_token" "$WEBHOOK_SECRET_PROPERTY" "$WEBHOOK_SECRET"

  secret_fingerprint="$(printf '%s' "$WEBHOOK_SECRET" | sha256sum | awk '{print substr($1,1,12)}')"
  echo "Webhook URL updated"
  echo "Webhook secret updated, fingerprint: $secret_fingerprint"
}

verify_webhook() {
  local access_token
  access_token="$(get_access_token)"

  curl --fail-with-body -sS --get \
    -H "Authorization: Bearer ${access_token}" \
    -H "Accept: application/json" \
    --data-urlencode "sysparm_query=nameIN${WEBHOOK_URL_PROPERTY},${WEBHOOK_SECRET_PROPERTY}" \
    --data-urlencode "sysparm_fields=name,value" \
    "$(servicenow_base_url)/api/now/table/sys_properties" | \
    jq --arg secret_name "$WEBHOOK_SECRET_PROPERTY" \
      '.result[] | if .name == $secret_name then .value = "<redacted>" else . end'
}

main() {
  local command_name="${1:-test}"

  case "$command_name" in
    help|-h|--help)
      usage
      return 0
      ;;
  esac

  load_env
  require_tools
  require_servicenow_env

  case "$command_name" in
    test) test_oauth ;;
    list-properties) list_properties ;;
    update-webhook) update_webhook ;;
    verify-webhook) verify_webhook ;;
    *)
      usage
      fail "Unknown command: $command_name"
      ;;
  esac
}

main "$@"
