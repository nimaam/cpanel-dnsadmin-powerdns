#!/bin/bash

# Script to test setup method exactly as WHM would call it

echo "=== Testing PowerDNS Setup Method (as WHM would call it) ==="
echo ""

# Test with the same parameters WHM would send
API_URL="http://ns0.ultaservers.com:8081/api/v1"
API_KEY="gPJJ4FdWvz4ngNvx"
USERNAME="root"
DEBUG="0"

echo "Parameters:"
echo "  API URL: $API_URL"
echo "  API Key: ${API_KEY:0:4}**** (hidden)"
echo "  Username: $USERNAME"
echo "  Debug: $DEBUG"
echo ""

# Remove existing config to test fresh setup
echo "1. Removing existing config file (if exists)..."
if [ -f "/var/cpanel/cluster/root/config/powerdns" ]; then
    rm -f /var/cpanel/cluster/root/config/powerdns
    echo "   ✅ Removed existing config"
else
    echo "   (No existing config to remove)"
fi
echo ""

# Test setup method as class method (how cPanel calls it)
echo "2. Calling setup method as class method..."
/usr/local/cpanel/3rdparty/bin/perl -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e '
use strict;
use warnings;

# Set REMOTE_USER (cPanel uses this)
$ENV{"REMOTE_USER"} = shift;

my $api_url = shift;
my $api_key = shift;
my $username = shift;
my $debug = shift;

eval {
    require Cpanel::NameServer::Setup::Remote::PowerDNS;
};
if ($@) {
    print "❌ Failed to load module: $@\n";
    exit 1;
}

print "   Module loaded successfully\n";
print "   Calling setup method...\n";

# Call setup as class method (Package->method)
my ($success, $message, $extra1, $extra2);
eval {
    ($success, $message, $extra1, $extra2) = Cpanel::NameServer::Setup::Remote::PowerDNS->setup(
        "user" => $username,
        "api_url" => $api_url,
        "apikey" => $api_key,
        "debug" => $debug ? 1 : 0
    );
};

if ($@) {
    print "❌ Error calling setup: $@\n";
    exit 1;
}

print "\n   Return values:\n";
print "   Success: " . ($success ? "1 (true)" : "0 (false)") . "\n";
print "   Message: $message\n";
print "   Extra1: " . ($extra1 || "(empty)") . "\n";
print "   Extra2: " . ($extra2 || "(empty)") . "\n";

if ($success) {
    print "\n✅ Setup successful!\n";
    exit 0;
} else {
    print "\n❌ Setup failed!\n";
    print "Error message: $message\n";
    exit 1;
}
' "$USERNAME" "$API_URL" "$API_KEY" "$USERNAME" "$DEBUG" 2>&1

EXIT_CODE=$?
echo ""

# Check if config was created
echo "3. Checking if config file was created..."
if [ -f "/var/cpanel/cluster/root/config/powerdns" ]; then
    echo "   ✅ Config file created successfully"
    echo "   Contents:"
    cat /var/cpanel/cluster/root/config/powerdns | sed 's/apikey=.*/apikey=***HIDDEN***/' | sed 's/pass=.*/pass=***HIDDEN***/' | sed 's/^/      /'
else
    echo "   ❌ Config file NOT created"
fi
echo ""

# Check setup log
echo "4. Checking setup log..."
if [ -f "/usr/local/cpanel/logs/dnsadmin_powerdns_setup_log" ]; then
    echo "   Last 10 lines from setup log:"
    tail -10 /usr/local/cpanel/logs/dnsadmin_powerdns_setup_log | sed 's/^/      /'
else
    echo "   ⚠️  Setup log not found (may not have been created yet)"
fi
echo ""

if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Test completed successfully!"
    echo ""
    echo "If this test passes but WHM still fails, the issue might be:"
    echo "  - How cPanel passes parameters to the setup method"
    echo "  - ACL/permission issues in web context"
    echo "  - Environment variable differences"
    echo ""
    echo "Next steps:"
    echo "  1. Check the setup log: tail -f /usr/local/cpanel/logs/dnsadmin_powerdns_setup_log"
    echo "  2. Try adding server in WHM while watching the log"
    echo "  3. Check cPanel error log: tail -f /usr/local/cpanel/logs/error_log"
else
    echo "❌ Test failed - this indicates the setup method has an issue"
    echo ""
    echo "Check the error message above and the setup log for details"
fi

echo ""
echo "=== Done ==="

