#!/usr/bin/env bash

set -euo pipefail

echo "Testing ServiceNow OAuth connection..."
echo "Instance: ${SERVICENOW_INSTANCE_URL}"

TOKEN_RESPONSE=$(curl -s -X POST \
  "${SERVICENOW_INSTANCE_URL}/oauth_token.do" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${SERVICENOW_CLIENT_ID}" \
  --data-urlencode "client_secret=${SERVICENOW_CLIENT_SECRET}")

echo ""
echo "Token Response:"
echo "${TOKEN_RESPONSE}" | jq .

ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // empty')

if [ -z "$ACCESS_TOKEN" ]; then
    echo ""
    echo "FAILED: Could not obtain access token"
    exit 1
fi

echo ""
echo "SUCCESS: Access token obtained"

echo ""
echo "Testing Incident API..."

curl -s \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Accept: application/json" \
  "${SERVICENOW_INSTANCE_URL}/api/now/table/incident?sysparm_limit=1" \
  | jq .


WEBHOOK_URL=dummyhttps://event-ai.us-east-1.api.aws/webhook/generic/4c48b5f2-30aa-4e09-84f2-c0d3d7c9e8ed
WEBHOOK_SECRET=YU0KHCMXIMTvGXPkswhLGUvpBTKMgd96RBKepsA7ZQ0=

echo -n "admin:4DNc4xkd//PF" | base64

  curl -X POST "https://dev208489.service-now.com/sync" \
  -u "admin:4DNc4xkd//PF" \
  -H "Content-Type: application/json" \
  -d '{
    "webhook_url": "'"${WEBHOOK_URL}"'",
    "webhook_secret": "'"${WEBHOOK_SECRET}"'"
  }'


  curl -v -X POST "https://dev208489.service-now.com/" \
  -u "admin:4DNc4xkd//PF" \
  -H "Content-Type: application/json" \
  -d '{
    "webhook_url": "https://test.url",
    "webhook_secret": "test_secret"
  }'

  

  curl -v -X POST "https://dev208489.service-now.com" \
  -H "Authorization: Basic YWRtaW46NEROYzR4a2QvL1BG" \
  -H "Content-Type: application/json" \
  -d '{
    "webhook_url": "https://test.url",
    "webhook_secret": "test_secret"
  }'
