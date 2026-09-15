#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

supabase_bin="${SUPABASE_BIN:-supabase}"
output_dir="$repo_root/supabase/.test-results"
response_file="$output_dir/edge-response.json"
serve_log="$output_dir/functions-serve.log"
local_env="${FUNCTIONS_ENV:-$repo_root/supabase/functions/.env.local}"
server_pid=""
api_url=""
service_role_key=""
owner_id=""
outsider_id=""

mkdir -p "$output_dir"
: > "$serve_log"

fail() {
  echo "error: $*" >&2
  if [[ -s "$response_file" ]]; then
    echo "Last response:" >&2
    sed -n '1,20p' "$response_file" >&2
  fi
  if [[ -s "$serve_log" ]]; then
    echo "Function log: $serve_log" >&2
  fi
  exit 1
}

for command_name in curl jq uuidgen; do
  command -v "$command_name" >/dev/null 2>&1 || fail "'$command_name' is required for Edge Function smoke tests."
done

SUPABASE_BIN="$supabase_bin" "$repo_root/scripts/check-backend-prerequisites.sh"
[[ -f "$local_env" ]] || fail "missing $local_env; create it from the safe local template in the implementation plan."

status_env="$($supabase_bin status -o env)"
env_value() {
  local key="$1"
  local value
  value="$(printf '%s\n' "$status_env" | awk -v prefix="$key=" 'index($0, prefix) == 1 { sub("^[^=]*=", ""); print; exit }')"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s' "$value"
}

api_url="$(env_value API_URL)"
anon_key="$(env_value ANON_KEY)"
service_role_key="$(env_value SERVICE_ROLE_KEY)"
[[ -n "$api_url" && -n "$anon_key" && -n "$service_role_key" ]] || fail "could not read local API credentials from 'supabase status -o env'."

stop_server() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" >/dev/null 2>&1; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  server_pid=""
}

temporary_dir="$(mktemp -d)"
cleanup() {
  stop_server
  for user_id in "$outsider_id" "$owner_id"; do
    if [[ -n "$api_url" && -n "$service_role_key" && -n "$user_id" ]]; then
      curl -sS -o /dev/null -X DELETE "$api_url/auth/v1/admin/users/$user_id" \
        -H "apikey: $service_role_key" \
        -H "Authorization: Bearer $service_role_key" || true
    fi
  done
  rm -rf "$temporary_dir"
}
trap cleanup EXIT INT TERM

start_server() {
  local env_file="$1"
  stop_server
  : > "$serve_log"
  "$supabase_bin" functions serve --env-file "$env_file" > "$serve_log" 2>&1 &
  server_pid="$!"

  local attempt status
  for attempt in $(seq 1 60); do
    if ! kill -0 "$server_pid" >/dev/null 2>&1; then
      fail "the local Edge Runtime exited before becoming ready."
    fi
    status="$(curl -sS -o "$response_file" -w '%{http_code}' \
      -X POST "$api_url/functions/v1/delete-account" \
      -H 'Content-Type: application/json' \
      --data '{}' || true)"
    if [[ "$status" == "401" ]]; then
      return
    fi
    sleep 0.5
  done
  fail "the local Edge Runtime did not become ready within 30 seconds."
}

request_function() {
  local function_name="$1"
  local token="$2"
  local body="$3"
  local headers=(-H 'Content-Type: application/json' -H "apikey: $anon_key")
  if [[ -n "$token" ]]; then
    headers+=(-H "Authorization: Bearer $token")
  fi
  curl -sS -o "$response_file" -w '%{http_code}' \
    -X POST "$api_url/functions/v1/$function_name" \
    "${headers[@]}" \
    --data "$body"
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label returned HTTP $actual; expected $expected."
  printf '  PASS  %s (HTTP %s)\n' "$label" "$actual"
}

api_request() {
  local method="$1"
  local path="$2"
  local key="$3"
  local token="$4"
  local body="${5:-}"
  local headers=(-H 'Content-Type: application/json' -H "apikey: $key")
  if [[ -n "$token" ]]; then
    headers+=(-H "Authorization: Bearer $token")
  fi
  local args=(-sS -o "$response_file" -w '%{http_code}' -X "$method" "$api_url$path")
  if [[ -n "$body" ]]; then
    args+=(--data "$body")
  fi
  curl "${args[@]}" "${headers[@]}"
}

dump_public_data() {
  local destination="$1"
  "$supabase_bin" db dump --local --data-only --use-copy --schema public \
    --file "$destination" >/dev/null
}

copy_rows_containing() {
  local dump_file="$1"
  local table_name="$2"
  local needle="$3"
  awk -v table_name="$table_name" -v needle="$needle" '
    $0 ~ "^COPY \\\"public\\\"\\.\\\"" table_name "\\\" " { inside = 1; next }
    inside && $0 == "\\." { inside = 0 }
    inside && index($0, needle) > 0 { count += 1 }
    END { print count + 0 }
  ' "$dump_file"
}

signup_user() {
  local email="$1"
  local password="$2"
  local body status
  body="$(jq -nc --arg email "$email" --arg password "$password" '{email:$email,password:$password}')"
  status="$(api_request POST '/auth/v1/signup' "$anon_key" '' "$body")"
  assert_status 200 "$status" "sign up $email" >&2
  jq -er '.access_token' "$response_file"
}

set_consent() {
  local token="$1"
  local purpose="$2"
  local version="$3"
  local body status
  body="$(jq -nc --arg purpose "$purpose" --arg version "$version" \
    '{p_purpose:$purpose,p_consent_version:$version,p_granted:true}')"
  status="$(api_request POST '/rest/v1/rpc/set_ai_consent' "$anon_key" "$token" "$body")"
  assert_status 204 "$status" "grant $purpose consent"
}

echo 'Edge Functions: authentication and safe missing-provider checks'
start_server "$local_env"

functions=(delete-account send-invitation ocr-receipt parse-receipt suggest-itinerary clarify-itinerary-locations)
for function_name in "${functions[@]}"; do
  status="$(request_function "$function_name" '' '{}')"
  assert_status 401 "$status" "$function_name rejects a missing JWT"
  status="$(request_function "$function_name" 'not-a-valid-jwt' '{}')"
  assert_status 401 "$status" "$function_name rejects an invalid JWT"
done

suffix="$(date +%s)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
password='TripSplit-Local-Edge-Only-2026!'
owner_email="edge-owner-$suffix@example.com"
outsider_email="edge-outsider-$suffix@example.com"
owner_token="$(signup_user "$owner_email" "$password")"
cp "$response_file" "$temporary_dir/owner-signup.json"
owner_id="$(jq -er '.user.id' "$temporary_dir/owner-signup.json")"
outsider_token="$(signup_user "$outsider_email" "$password")"
cp "$response_file" "$temporary_dir/outsider-signup.json"
outsider_id="$(jq -er '.user.id' "$temporary_dir/outsider-signup.json")"

set_consent "$owner_token" receipt_processing 2026-08-02
set_consent "$owner_token" itinerary_generation 2026-08-06

trip_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
trip_document="$(jq -nc --arg id "$trip_id" --arg owner "$owner_id" '{
  id:$id,name:"Local Edge Function Trip",currencyCode:"USD",creatorID:$owner,
  members:[],budgets:{},expenses:[],deletedExpenses:[],settlementRecords:{},comments:{}
}')"
trip_body="$(jq -nc --arg id "$trip_id" --arg owner "$owner_id" --argjson data "$trip_document" \
  '{p_id:$id,p_user_id:$owner,p_data:$data,p_previous_data:null}')"
status="$(api_request POST '/rest/v1/rpc/sync_trip_normalized' "$anon_key" "$owner_token" "$trip_body")"
assert_status 200 "$status" 'create local function-test trip'

status="$(request_function send-invitation "$owner_token" "$(jq -nc --arg id "$trip_id" '{tripID:$id,email:"safe-missing@example.com"}')")"
assert_status 503 "$status" 'send-invitation fails safely without Resend'
status="$(request_function ocr-receipt "$owner_token" '{"imageBase64":"//j/2Q==","mimeType":"image/jpeg"}')"
assert_status 503 "$status" 'ocr-receipt fails safely without Vision'
status="$(request_function parse-receipt "$owner_token" '{"text":"Coffee 4.50"}')"
assert_status 503 "$status" 'parse-receipt fails safely without an LLM provider'
status="$(request_function suggest-itinerary "$owner_token" '{"location":"Localhost","days":1,"currency":"USD","totalBudget":10}')"
assert_status 503 "$status" 'suggest-itinerary fails safely without an LLM provider'
status="$(request_function clarify-itinerary-locations "$owner_token" '{"destination":"Localhost","stops":[{"stopID":"11111111-1111-4111-8111-111111111111","name":"Old town walk","kind":"activity","area":"Localhost"}]}')"
assert_status 503 "$status" 'clarify-itinerary-locations fails safely without Claude'

missing_provider_dump="$temporary_dir/missing-provider-data.sql"
dump_public_data "$missing_provider_dump"
[[ "$(copy_rows_containing "$missing_provider_dump" receipt_scan_events "$owner_id")" == "0" ]] || fail 'missing provider configuration consumed AI quota.'
printf '  PASS  missing provider configuration consumes no AI quota\n'

[[ "$(copy_rows_containing "$missing_provider_dump" trip_invitations "$trip_id")" == "0" ]] || fail 'missing email provider configuration created an invitation.'
printf '  PASS  missing email provider configuration creates no invitation\n'

mock_env="$temporary_dir/functions-mock.env"
awk '$0 !~ /^LOCAL_PROVIDER_MOCKS=/' "$local_env" > "$mock_env"
printf '\nLOCAL_PROVIDER_MOCKS=true\n' >> "$mock_env"

echo 'Edge Functions: authenticated local provider-mock paths'
start_server "$mock_env"

status="$(request_function ocr-receipt "$owner_token" '{"imageBase64":"//j/2Q==","mimeType":"image/jpeg"}')"
assert_status 200 "$status" 'ocr-receipt authenticated mock path'
jq -e '.lines[0] == "Coffee 4.50"' "$response_file" >/dev/null || fail 'ocr-receipt mock response shape is invalid.'

status="$(request_function parse-receipt "$owner_token" '{"text":"Coffee 4.50"}')"
assert_status 200 "$status" 'parse-receipt authenticated mock path'
jq -e '.merchant == "TripSplit Local Cafe" and (.items | length) == 1' "$response_file" >/dev/null || fail 'parse-receipt mock response shape is invalid.'

status="$(request_function suggest-itinerary "$owner_token" '{"location":"Localhost","days":1,"currency":"USD","totalBudget":10}')"
assert_status 200 "$status" 'suggest-itinerary authenticated mock path'
jq -e '(.days | length) == 1 and (.days[0].stops | length) == 1 and .days[0].stops[0].area == "Localhost"' "$response_file" >/dev/null || fail 'suggest-itinerary mock response shape is invalid or lost its location area.'

status="$(request_function clarify-itinerary-locations "$owner_token" '{"destination":"Localhost","stops":[{"stopID":"11111111-1111-4111-8111-111111111111","name":"Old town walk","kind":"activity","area":"Localhost"}]}')"
assert_status 200 "$status" 'clarify-itinerary-locations authenticated mock path'
jq -e '.hints[0].stopID == "11111111-1111-4111-8111-111111111111" and .hints[0].canonicalName == "Old town walk" and .hints[0].confidence >= 0.65' "$response_file" >/dev/null || fail 'clarify-itinerary-locations mock response shape is invalid.'

owner_invite_email="edge-invite-$suffix@example.com"
status="$(request_function send-invitation "$owner_token" "$(jq -nc --arg id "$trip_id" --arg email "$owner_invite_email" '{tripID:$id,email:$email}')")"
assert_status 202 "$status" 'send-invitation owner mock path'

denied_email="edge-denied-$suffix@example.com"
status="$(request_function send-invitation "$outsider_token" "$(jq -nc --arg id "$trip_id" --arg email "$denied_email" '{tripID:$id,email:$email}')")"
assert_status 500 "$status" 'send-invitation enforces trip ownership in the database'
mock_provider_dump="$temporary_dir/mock-provider-data.sql"
dump_public_data "$mock_provider_dump"
[[ "$(copy_rows_containing "$mock_provider_dump" trip_invitations "$owner_invite_email")" == "1" ]] || fail 'owner invitation did not create exactly one database row.'
printf '  PASS  owner invitation creates one database row\n'
[[ "$(copy_rows_containing "$mock_provider_dump" trip_invitations "$denied_email")" == "0" ]] || fail 'database authorization allowed a non-owner invitation.'
printf '  PASS  denied invitation creates no database row\n'

status="$(request_function delete-account "$outsider_token" '{}')"
assert_status 204 "$status" 'delete-account authenticated path'
status="$(api_request GET '/auth/v1/user' "$anon_key" "$outsider_token")"
[[ "$status" != "200" ]] || fail 'delete-account left the deleted user session valid.'
printf '  PASS  deleted user JWT no longer resolves (HTTP %s)\n' "$status"

status="$(request_function delete-account "$owner_token" '{}')"
assert_status 204 "$status" 'delete-account fixture cleanup'

stop_server
echo 'All local Edge Function smoke tests passed; no paid provider endpoint was called.'
