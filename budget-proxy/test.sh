#!/usr/bin/env bash
# Proof of the budget-proxy's safety properties against a LIVE deployment.
# Tokens/URL come from the environment — never hardcode a secret here.
#
#   BUDGET_PROXY_URL=https://arena-budget-proxy.<sub>.workers.dev \
#   BUDGET_PROXY_TOKEN=... ADMIN_TOKEN=... ./test.sh
#
# Assumes TOTAL_CAP_CENTS=2000 ($20). Leaves the ledger clean (spent:0) on success.
set -euo pipefail

: "${BUDGET_PROXY_URL:?set BUDGET_PROXY_URL}"
: "${BUDGET_PROXY_TOKEN:?set BUDGET_PROXY_TOKEN}"
: "${ADMIN_TOKEN:?set ADMIN_TOKEN}"
URL="$BUDGET_PROXY_URL"
AUTH="authorization: Bearer $BUDGET_PROXY_TOKEN"
fail() { echo "FAIL: $1"; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# fail-closed auth
[ "$(code "$URL/status")" = "401" ] || fail "no-auth should be 401"
[ "$(code -H 'authorization: Bearer nope' "$URL/status")" = "401" ] || fail "wrong token should be 401"
[ "$(code -X POST -H "$AUTH" -H 'x-admin-token: nope' "$URL/admin/reset")" = "401" ] || fail "bad admin should be 401"

# fail-closed input
[ "$(code -X POST -H "$AUTH" -d '{"amountCents":-5}' "$URL/authorize")" = "400" ] || fail "negative amount should be 400"
[ "$(code -X POST -H "$AUTH" -d 'not-json' "$URL/authorize")" = "400" ] || fail "malformed json should be 400"

# clean slate, then cap enforcement
curl -s -X POST -H "$AUTH" -H "x-admin-token: $ADMIN_TOKEN" "$URL/admin/reset" >/dev/null
curl -s -X POST -H "$AUTH" -d '{"amountCents":1500}' "$URL/authorize" | grep -q '"approved":true'  || fail "1500 should approve"
curl -s -X POST -H "$AUTH" -d '{"amountCents":1000}' "$URL/authorize" | grep -q '"approved":false' || fail "1000 should refuse (over cap)"
curl -s -X POST -H "$AUTH" -d '{"amountCents":500}'  "$URL/authorize" | grep -q '"approved":true'  || fail "500 should approve to cap"
curl -s -X POST -H "$AUTH" -d '{"amountCents":1}'    "$URL/authorize" | grep -q '"approved":false' || fail "1 should refuse at cap"

# atomicity under concurrency: 40 parallel $1 vs $20 cap => exactly 20 approved
curl -s -X POST -H "$AUTH" -H "x-admin-token: $ADMIN_TOKEN" "$URL/admin/reset" >/dev/null
APPROVED=$(for _ in $(seq 1 40); do curl -s -X POST -H "$AUTH" -d '{"amountCents":100}' "$URL/authorize" & done | grep -c '"approved":true')
wait
[ "$APPROVED" = "20" ] || fail "concurrency: expected exactly 20 approved, got $APPROVED"
curl -s -H "$AUTH" "$URL/status" | grep -q '"spent":2000' || fail "concurrency: spent should be exactly 2000"

# leave clean
curl -s -X POST -H "$AUTH" -H "x-admin-token: $ADMIN_TOKEN" "$URL/admin/reset" >/dev/null
echo "PASS — fail-closed auth+input, cap enforcement, and atomic-under-concurrency all verified."
