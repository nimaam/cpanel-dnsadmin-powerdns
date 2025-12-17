#!/bin/bash

# Script to check for setup errors in detail

echo "=== Checking PowerDNS Setup Errors ==="
echo ""

# 1. Check recent error logs
echo "1. Recent PowerDNS-related errors in cPanel error log..."
if [ -f "/usr/local/cpanel/logs/error_log" ]; then
    echo "   Last 20 lines with PowerDNS or DNS cluster mentions:"
    grep -i -E "powerdns|dns.*cluster|setup.*remote" /usr/local/cpanel/logs/error_log 2>/dev/null | tail -20 | sed 's/^/      /' || echo "      (no relevant errors found)"
else
    echo "   ⚠️  Error log not found"
fi

echo ""

# 2. Check dnsadmin logs
echo "2. Checking dnsadmin logs..."
DNSADMIN_LOG="/var/log/dnsadmin_log"
if [ -f "$DNSADMIN_LOG" ]; then
    echo "   Last 20 lines:"
    tail -20 "$DNSADMIN_LOG" | sed 's/^/      /'
else
    echo "   ⚠️  dnsadmin log not found at $DNSADMIN_LOG"
    echo "   Checking alternative locations..."
    find /var/log -name "*dnsadmin*" -type f 2>/dev/null | head -5 | while read log; do
        echo "      Found: $log"
    done
fi

echo ""

# 3. Test the setup method directly
echo "3. Testing setup method with current config..."
CONFIG_FILE="/var/cpanel/cluster/root/config/powerdns"
if [ -f "$CONFIG_FILE" ]; then
    echo "   Reading config from: $CONFIG_FILE"
    API_URL=$(grep "^api_url=" "$CONFIG_FILE" | cut -d'=' -f2)
    API_KEY=$(grep "^apikey=" "$CONFIG_FILE" | cut -d'=' -f2)
    
    if [ -z "$API_KEY" ]; then
        API_KEY=$(grep "^pass=" "$CONFIG_FILE" | cut -d'=' -f2)
    fi
    
    echo "   API URL: $API_URL"
    echo "   API Key: ${API_KEY:0:4}**** (hidden)"
    echo ""
    echo "   Testing API connectivity..."
    TEST_URL="$API_URL/servers/localhost"
    CURL_OUTPUT=$(curl -s -w "\nHTTP_CODE:%{http_code}" -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" -H "Accept: application/json" --max-time 10 "$TEST_URL" 2>&1)
    
    HTTP_CODE=$(echo "$CURL_OUTPUT" | grep "HTTP_CODE:" | cut -d':' -f2)
    if [ "$HTTP_CODE" = "200" ]; then
        echo "   ✅ API connectivity test passed (HTTP $HTTP_CODE)"
    else
        echo "   ❌ API connectivity test failed (HTTP $HTTP_CODE)"
        echo "   Response: $(echo "$CURL_OUTPUT" | grep -v "HTTP_CODE" | head -5)"
    fi
else
    echo "   ⚠️  Config file not found"
fi

echo ""

# 4. Check file permissions
echo "4. Checking file permissions..."
echo "   Config file:"
ls -la /var/cpanel/cluster/root/config/powerdns 2>/dev/null | awk '{print "      " $1 " " $3 ":" $4 " " $9}'
echo "   Cluster directory:"
ls -ld /var/cpanel/cluster/root/config 2>/dev/null | awk '{print "      " $1 " " $3 ":" $4 " " $9}'

echo ""

# 5. Check if REMOTE_USER is set (needed for setup)
echo "5. Environment check..."
echo "   REMOTE_USER: ${REMOTE_USER:-not set}"
echo "   USER: ${USER:-not set}"
echo "   Note: setup method uses REMOTE_USER or 'root' as fallback"

echo ""

# 6. Test module loading in cPanel context
echo "6. Testing module in cPanel context..."
if [ -f "/usr/local/cpanel/3rdparty/bin/perl" ]; then
    CPANEL_PERL="/usr/local/cpanel/3rdparty/bin/perl"
else
    CPANEL_PERL="/usr/bin/perl"
fi

echo "   Testing if setup method can be called..."
TEST_SCRIPT=$(cat <<'EOF'
use strict;
use warnings;
BEGIN {
    unshift @INC, '/usr/local/cpanel/Cpanel';
    unshift @INC, '/usr/local/cpanel';
}
eval {
    require Cpanel::NameServer::Setup::Remote::PowerDNS;
    my $result = Cpanel::NameServer::Setup::Remote::PowerDNS::get_config();
    if (ref($result) eq 'ARRAY') {
        print "OK - get_config returns array\n";
    } else {
        print "WARNING - get_config returns: " . (ref($result) || 'scalar') . "\n";
    }
};
if ($@) {
    print "ERROR: $@\n";
}
EOF
)

$CPANEL_PERL -e "$TEST_SCRIPT" 2>&1 | sed 's/^/      /'

echo ""

# 7. Recommendations
echo "=== Recommendations ==="
echo ""
echo "If you're getting 'Failed to set up DNS cluster for module PowerDNS':"
echo ""
echo "1. Check the actual error in logs:"
echo "   tail -f /usr/local/cpanel/logs/error_log"
echo "   (Then try adding the server in WHM and watch for errors)"
echo ""
echo "2. Check dnsadmin logs:"
echo "   tail -f /var/log/dnsadmin_log"
echo ""
echo "3. Verify API connectivity:"
echo "   curl -H 'X-API-Key: YOUR_KEY' http://ns0.ultaservers.com:8081/api/v1/servers/localhost"
echo ""
echo "4. Try removing the existing config and re-adding:"
echo "   rm /var/cpanel/cluster/root/config/powerdns"
echo "   (Then add through WHM interface again)"
echo ""
echo "5. Check that dnsadmin is NOT dormant:"
echo "   WHM >> Tweak Settings >> Dormant services"
echo "   (dnsadmin should be unchecked)"
echo ""





