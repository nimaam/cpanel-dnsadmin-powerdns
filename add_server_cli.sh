#!/bin/bash

# CLI script to add PowerDNS server to cPanel DNS cluster
# This helps debug setup issues by calling the setup method directly

if [ $# -lt 3 ]; then
    echo "Usage: $0 <API_URL> <API_KEY> <USERNAME>"
    echo "Example: $0 http://ns0.ultaservers.com:8081/api/v1 gPJJ4FdWvz4ngNvx root"
    exit 1
fi

API_URL="$1"
API_KEY="$2"
USERNAME="$3"
DEBUG="${4:-0}"

echo "=== Adding PowerDNS Server via CLI ==="
echo ""
echo "API URL: $API_URL"
echo "API Key: ${API_KEY:0:4}**** (hidden)"
echo "Username: $USERNAME"
echo "Debug: $DEBUG"
echo ""

# Test API connectivity first
echo "1. Testing API connectivity..."
RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" --max-time 10 \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "$API_URL/servers/localhost" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "200" ]; then
    echo "   ❌ API connectivity test failed (HTTP $HTTP_CODE)"
    echo "   Please fix API connectivity before proceeding"
    exit 1
fi
echo "   ✅ API connectivity test passed"
echo ""

# Call setup method directly via Perl
echo "2. Calling setup method..."
/usr/local/cpanel/3rdparty/bin/perl -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e '
use Cpanel::NameServer::Setup::Remote::PowerDNS;

my $api_url = shift;
my $api_key = shift;
my $username = shift;
my $debug = shift;

# Create a mock object (setup is called as instance method)
my $module = bless({}, "Cpanel::NameServer::Setup::Remote::PowerDNS");

my ($success, $message, $extra1, $extra2) = $module->setup(
    "user" => $username,
    "api_url" => $api_url,
    "apikey" => $api_key,
    "debug" => $debug ? 1 : 0
);

if ($success) {
    print "✅ Setup successful!\n";
    print "Message: $message\n";
    print "Extra1: " . ($extra1 || "N/A") . "\n";
    print "Extra2: " . ($extra2 || "N/A") . "\n";
    exit 0;
} else {
    print "❌ Setup failed!\n";
    print "Error: $message\n";
    exit 1;
}
' "$API_URL" "$API_KEY" "$USERNAME" "$DEBUG" 2>&1

EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "3. Verifying config file was created..."
    CONFIG_FILE="/var/cpanel/cluster/$USERNAME/config/powerdns"
    if [ -f "$CONFIG_FILE" ]; then
        echo "   ✅ Config file created: $CONFIG_FILE"
        echo "   Contents (API key hidden):"
        cat "$CONFIG_FILE" | sed 's/apikey=.*/apikey=***HIDDEN***/' | sed 's/pass=.*/pass=***HIDDEN***/'
    else
        echo "   ⚠️  Config file not found (may be in different location)"
        find /var/cpanel/cluster -name "powerdns" -type f 2>/dev/null | while read f; do
            echo "   Found: $f"
        done
    fi
    echo ""
    echo "✅ PowerDNS server added successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Go to: WHM >> Clusters >> DNS Cluster"
    echo "2. The PowerDNS server should now appear in the list"
    echo "3. You can test by adding a zone"
else
    echo "❌ Failed to add PowerDNS server"
    echo ""
    echo "Check the error message above for details"
    echo "Common issues:"
    echo "  - ACL/permission problems"
    echo "  - API connection issues"
    echo "  - Invalid credentials"
fi

echo ""
echo "=== Done ==="

