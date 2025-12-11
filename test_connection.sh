#!/bin/bash

# Test PowerDNS API connection script
# This helps diagnose connection issues

API_URL="${1:-http://159.100.6.2:8081/api/v1}"
API_KEY="${2:-gPJJ4FdWvz4ngNvx}"

echo "=== PowerDNS API Connection Test ==="
echo ""
echo "API URL: $API_URL"
echo "API Key: ${API_KEY:0:4}**** (hidden)"
echo ""

# Normalize URL
API_URL=$(echo "$API_URL" | sed 's|/*$||')
if [[ ! "$API_URL" =~ /api/v1$ ]]; then
    API_URL="${API_URL}/api/v1"
fi

TEST_URL="${API_URL}/servers/localhost"

echo "Testing connection to: $TEST_URL"
echo ""

# Test connection
RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" "$TEST_URL")
HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

echo "HTTP Status Code: $HTTP_CODE"
echo ""

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Connection successful!"
    echo ""
    echo "Response:"
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
else
    echo "❌ Connection failed!"
    echo ""
    echo "Error Response:"
    echo "$BODY"
    echo ""
    echo "Troubleshooting:"
    echo "1. Verify the API URL is correct: $API_URL"
    echo "2. Verify the API key is correct"
    echo "3. Check firewall rules between cPanel server and PowerDNS server"
    echo "4. Verify PowerDNS API is enabled and running"
    echo "5. Check PowerDNS server logs"
fi

echo ""
echo "=== Test Complete ==="

