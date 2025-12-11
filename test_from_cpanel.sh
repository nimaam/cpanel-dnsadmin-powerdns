#!/bin/bash

# Test PowerDNS API connectivity from cPanel server
# This helps verify if the cPanel server can reach the PowerDNS API

API_URL="http://159.100.6.2:8081/api/v1"
API_KEY="gPJJ4FdWvz4ngNvx"

echo "=== Testing PowerDNS API from cPanel Server ==="
echo ""

# Test 1: Basic connectivity
echo "1. Testing basic connectivity to PowerDNS server..."
if ping -c 1 -W 2 159.100.6.2 &>/dev/null; then
    echo "   ✓ Server is reachable (ping successful)"
else
    echo "   ✗ Server is NOT reachable (ping failed)"
    echo "      This could be a firewall or network issue"
fi

echo ""

# Test 2: Port connectivity
echo "2. Testing port 8081 connectivity..."
if timeout 3 bash -c "echo >/dev/tcp/159.100.6.2/8081" 2>/dev/null; then
    echo "   ✓ Port 8081 is open and accessible"
else
    echo "   ✗ Port 8081 is NOT accessible"
    echo "      Check firewall rules on both servers"
fi

echo ""

# Test 3: HTTP connectivity
echo "3. Testing HTTP connectivity to API..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "X-API-Key: $API_KEY" "$API_URL/servers/localhost" 2>&1)
if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✓ API is accessible (HTTP 200)"
elif [ "$HTTP_CODE" = "000" ]; then
    echo "   ✗ Cannot connect to API (connection timeout or refused)"
    echo "      Possible causes:"
    echo "      - Firewall blocking connection"
    echo "      - PowerDNS API not listening on 159.100.6.2:8081"
    echo "      - Network routing issue"
else
    echo "   ⚠️  API returned HTTP $HTTP_CODE"
    echo "      This might indicate authentication or configuration issues"
fi

echo ""

# Test 4: Full API test
echo "4. Testing full API request..."
RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" --max-time 5 -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" "$API_URL/servers/localhost" 2>&1)
HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✓ API connection successful!"
    echo "   Response preview:"
    echo "$BODY" | head -3 | sed 's/^/      /'
else
    echo "   ✗ API connection failed (HTTP $HTTP_CODE)"
    if [ -n "$BODY" ]; then
        echo "   Error response:"
        echo "$BODY" | head -5 | sed 's/^/      /'
    fi
fi

echo ""

# Test 5: Check if PowerDNS is listening on the expected interface
echo "5. Checking local PowerDNS configuration..."
if [ -f "/etc/powerdns/pdns.conf" ]; then
    echo "   PowerDNS config found:"
    grep -E "webserver|api|webserver-address|webserver-port" /etc/powerdns/pdns.conf 2>/dev/null | head -5 | sed 's/^/      /' || echo "      (no webserver config found)"
else
    echo "   ⚠️  PowerDNS config not found at /etc/powerdns/pdns.conf"
fi

echo ""
echo "=== Summary ==="
echo "If all tests pass, the API should be accessible from cPanel."
echo "If tests fail, check:"
echo "  1. Firewall rules (allow port 8081 from cPanel server)"
echo "  2. PowerDNS API configuration (webserver-address and webserver-port)"
echo "  3. Network connectivity between servers"
echo ""

