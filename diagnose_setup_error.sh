#!/bin/bash

# Diagnostic script to help identify why PowerDNS setup is failing

echo "=== PowerDNS Setup Error Diagnostic ==="
echo ""

# Check if password field is visible in the form
echo "1. Checking if password field might be missing..."
echo "   When you access: WHM >> Clusters >> DNS Cluster >> Add a DNS Server"
echo "   Then select 'PowerDNS' and click 'Configure'"
echo "   Do you see a field labeled 'PowerDNS API Token'? (Yes/No)"
echo ""

# Check recent error logs
echo "2. Checking recent cPanel error logs..."
if [ -f "/usr/local/cpanel/logs/error_log" ]; then
    echo "   Last 30 lines with PowerDNS/dnsadmin/setup errors:"
    tail -100 /usr/local/cpanel/logs/error_log | grep -i -E "powerdns|dnsadmin.*setup|setup.*powerdns|api.*token|pass.*required" | tail -10 || echo "   (no relevant errors found)"
else
    echo "   ⚠️  Error log not found"
fi

echo ""

# Check if config file was created
echo "3. Checking if config file was created..."
if [ -d "/var/cpanel/cluster" ]; then
    CONFIG_FILES=$(find /var/cpanel/cluster -name "powerdns" -type f 2>/dev/null)
    if [ -n "$CONFIG_FILES" ]; then
        echo "   ✓ Config file(s) found:"
        echo "$CONFIG_FILES" | while read config; do
            echo "      $config"
            if [ -r "$config" ]; then
                echo "      Contents:"
                cat "$config" | sed 's/pass=.*/pass=***HIDDEN***/' | sed 's/^/        /'
            fi
        done
    else
        echo "   ✗ No PowerDNS config file found"
        echo "      This suggests the setup method failed before creating the config"
    fi
else
    echo "   ⚠️  Cluster directory not found"
fi

echo ""

# Check module file
echo "4. Checking Setup module for potential issues..."
SETUP_FILE="/usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm"
if [ -f "$SETUP_FILE" ]; then
    echo "   ✓ Setup module exists"
    
    # Check if password field is defined
    if grep -q '"name" => "pass"' "$SETUP_FILE"; then
        echo "   ✓ Password field ('pass') is defined in get_config"
    else
        echo "   ✗ Password field ('pass') NOT found in get_config!"
    fi
    
    # Check if setup method checks for pass
    if grep -q '\$OPTS{"pass"}' "$SETUP_FILE"; then
        echo "   ✓ Setup method checks for 'pass' field"
    else
        echo "   ✗ Setup method does NOT check for 'pass' field!"
    fi
else
    echo "   ✗ Setup module not found!"
fi

echo ""

# Test API connection manually
echo "5. Testing API connection (same as setup method would)..."
API_URL="http://159.100.6.2:8081/api/v1"
API_KEY="gPJJ4FdWvz4ngNvx"
TEST_URL="${API_URL}/servers/localhost"

RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" --max-time 10 -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" "$TEST_URL" 2>&1)
HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

if [ "$HTTP_CODE" = "200" ]; then
    echo "   ✓ API connection test successful (HTTP 200)"
else
    echo "   ✗ API connection test failed (HTTP $HTTP_CODE)"
    echo "      This might be why setup is failing"
    if [ -n "$BODY" ]; then
        echo "      Error response:"
        echo "$BODY" | head -3 | sed 's/^/        /'
    fi
fi

echo ""

# Recommendations
echo "=== Recommendations ==="
echo ""
echo "Most likely causes:"
echo "1. Password field not visible/submitted:"
echo "   - Check if 'PowerDNS API Token' field appears in the form"
echo "   - If not, the field might not be rendering (cPanel UI issue)"
echo ""
echo "2. Connection test failing:"
echo "   - Even though curl works, LWP::UserAgent might have issues"
echo "   - Check firewall rules, SSL certificates, or network timeouts"
echo ""
echo "3. Check the exact error message:"
echo "   - The error should show more details than 'Failed to set up DNS cluster'"
echo "   - Look in cPanel error logs for the actual error from our setup method"
echo ""
echo "Next steps:"
echo "1. Reinstall the updated module:"
echo "   cd ~/cpanel-dnsadmin-powerdns && ./install.sh"
echo ""
echo "2. Clear cache and restart:"
echo "   /usr/local/cpanel/scripts/update_cpanel_cache"
echo "   /scripts/restartsrv_cpsrvd"
echo ""
echo "3. Try adding the server again and watch logs:"
echo "   tail -f /usr/local/cpanel/logs/error_log | grep -i powerdns"
echo ""





