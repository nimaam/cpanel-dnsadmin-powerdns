#!/bin/bash

# Test PowerDNS API connection script
# This helps diagnose connection issues
# Usage: ./test_connection.sh [API_URL] [API_KEY]

if [ $# -lt 2 ]; then
    echo "Usage: $0 <API_URL> <API_KEY>"
    echo "Example: $0 http://ns0.ultahost.com:8081/api/v1 your-api-key"
    exit 1
fi

API_URL="$1"
API_KEY="$2"

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

# Extract host and port from URL
if [[ "$API_URL" =~ ^https?://([^:/]+)(:([0-9]+))? ]]; then
    HOST="${BASH_REMATCH[1]}"
    PORT="${BASH_REMATCH[3]:-80}"
    if [[ "$API_URL" =~ ^https:// ]]; then
        PORT="${BASH_REMATCH[3]:-443}"
    fi
else
    echo "❌ Invalid URL format: $API_URL"
    exit 1
fi

echo "Extracted host: $HOST"
echo "Extracted port: $PORT"
echo ""

# Test 1: DNS Resolution
echo "1. Testing DNS resolution..."
if host "$HOST" >/dev/null 2>&1 || getent hosts "$HOST" >/dev/null 2>&1; then
    RESOLVED_IP=$(getent hosts "$HOST" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$RESOLVED_IP" ]; then
        echo "   ✅ DNS resolution successful: $HOST -> $RESOLVED_IP"
    else
        echo "   ⚠️  DNS resolved but couldn't get IP address"
    fi
else
    echo "   ❌ DNS resolution failed for $HOST"
    echo "      Check if the hostname is correct and DNS is working"
    exit 1
fi

# Test 2: Port Connectivity
echo ""
echo "2. Testing port connectivity..."
if timeout 3 bash -c "echo >/dev/tcp/$HOST/$PORT" 2>/dev/null; then
    echo "   ✅ Port $PORT is open and accessible"
else
    echo "   ❌ Port $PORT is NOT accessible"
    echo "      Possible causes:"
    echo "      - Firewall blocking connection"
    echo "      - Service not listening on this port"
    echo "      - Network routing issue"
    echo ""
    echo "   Testing with curl verbose output..."
    curl -v --max-time 5 -H "X-API-Key: $API_KEY" "$API_URL/servers/localhost" 2>&1 | head -20
    exit 1
fi

# Test 3: HTTP Connection
echo ""
echo "3. Testing HTTP connection..."
TEST_URL="${API_URL}/servers/localhost"
echo "   URL: $TEST_URL"
echo ""

# Test connection with verbose error info
RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}\nTIME_TOTAL:%{time_total}\nCONNECT_TIME:%{time_connect}" \
    --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "$TEST_URL" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
TIME_TOTAL=$(echo "$RESPONSE" | grep "TIME_TOTAL:" | cut -d: -f2)
CONNECT_TIME=$(echo "$RESPONSE" | grep "CONNECT_TIME:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d' | sed '/TIME_TOTAL:/d' | sed '/CONNECT_TIME:/d')

echo "HTTP Status Code: $HTTP_CODE"
if [ -n "$TIME_TOTAL" ]; then
    echo "Connection Time: ${CONNECT_TIME}s"
    echo "Total Time: ${TIME_TOTAL}s"
fi
echo ""

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Connection successful!"
    echo ""
    echo "Response:"
    echo "$BODY" | python3 -m json.tool 2>/dev/null || python -m json.tool 2>/dev/null || echo "$BODY"
elif [ "$HTTP_CODE" = "000" ]; then
    echo "❌ Connection failed (HTTP 000 - No connection established)"
    echo ""
    echo "This usually means:"
    echo "  - Connection timeout"
    echo "  - Connection refused"
    echo "  - DNS resolution failed"
    echo "  - Network unreachable"
    echo "  - Firewall blocking"
    echo ""
    echo "Error details:"
    echo "$BODY" | head -10
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Verify PowerDNS is running: systemctl status pdns"
    echo "2. Check if API is listening: netstat -tlnp | grep 8081"
    echo "3. Test from PowerDNS server: curl -H 'X-API-Key: YOUR_KEY' http://localhost:8081/api/v1/servers/localhost"
    echo "4. Check firewall: iptables -L -n | grep 8081"
    echo "5. Check PowerDNS config: grep -E 'webserver|api' /etc/pdns/pdns.conf"
elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    echo "❌ Authentication failed (HTTP $HTTP_CODE)"
    echo ""
    echo "Error Response:"
    echo "$BODY" | head -5
    echo ""
    echo "Check:"
    echo "  - API key is correct"
    echo "  - API key has proper permissions"
    echo "  - PowerDNS API authentication is configured correctly"
else
    echo "❌ Connection failed (HTTP $HTTP_CODE)"
    echo ""
    echo "Error Response:"
    echo "$BODY" | head -10
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

