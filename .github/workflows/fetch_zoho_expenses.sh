#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

ORG_ID="${ZOHO_ORG_ID:-60012618957}"
DATE_START="${DATE_START:-2026-10-01}"
BASE_URL="https://www.zohoapis.in/books/v3"

rm -rf /tmp/zoho_nb_exp && mkdir -p /tmp/zoho_nb_exp

TOKEN_RESPONSE=$(curl -sS -X POST "https://accounts.zoho.in/oauth/v2/token" \
  -d "grant_type=refresh_token" \
  -d "client_id=$ZOHO_CLIENT_ID" \
  -d "client_secret=$ZOHO_CLIENT_SECRET" \
  -d "refresh_token=$ZOHO_BOOKS_REFRESH_TOKEN")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r ".access_token // empty")
if [ -z "$ACCESS_TOKEN" ]; then
  echo "Zoho Books OAuth Error:" && echo "$TOKEN_RESPONSE" | jq .
  exit 1
fi

echo "Pulling Expenses from $DATE_START (customer_id != '' & is_billable == false)..."
PAGE=1
while true; do
  FILE_PAGE=$(printf "%05d" "$PAGE")

  RESPONSE=$(curl -sS -G "$BASE_URL/expenses" \
    -H "Authorization: Zoho-oauthtoken $ACCESS_TOKEN" \
    --data-urlencode "organization_id=$ORG_ID" \
    --data-urlencode "date_start=$DATE_START" \
    --data-urlencode "page=$PAGE" \
    --data-urlencode "per_page=200")

  echo "$RESPONSE" | jq -e ".expenses" >/dev/null || {
    echo "Expenses API Error on page $PAGE:" && echo "$RESPONSE" | jq .
    exit 1
  }

  echo "$RESPONSE" | jq '[
    .expenses[] |
    select(((.customer_id // "") | tostring) != "" and (.is_billable // false) == false) |
    {
      expense_id: (.expense_id | tostring),
      reference_number: (.reference_number // ""),
      date: (.date // ""),
      status: (.status // ""),
      branch_name: (.branch_name // ""),
      vendor_name: (.vendor_name // ""),
      customer_id: (.customer_id | tostring),
      customer_name: (.customer_name // ""),
      account_name: (.account_name // ""),
      description: (.description // ""),
      is_billable: (.is_billable // false),
      amount: (.total // 0),
      bcy_amount: (.bcy_total // .total // 0)
    }
  ]' > "/tmp/zoho_nb_exp/page_${FILE_PAGE}.json"

  MATCHES=$(jq "length" "/tmp/zoho_nb_exp/page_${FILE_PAGE}.json")
  HAS_MORE=$(echo "$RESPONSE" | jq -r ".page_context.has_more_page // false")
  echo "  Page $PAGE: $MATCHES matching expenses"

  [ "$HAS_MORE" != "true" ] && break
  PAGE=$((PAGE + 1))
  sleep 0.65
done

FILES=(/tmp/zoho_nb_exp/page_*.json)
if [ ${#FILES[@]} -gt 0 ]; then
  jq -s "add" "${FILES[@]}" > expenses.json
else
  echo "[]" > expenses.json
fi
rm -rf /tmp/zoho_nb_exp

echo "Total expenses saved to expenses.json: $(jq 'length' expenses.json)"
