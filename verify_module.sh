#!/bin/bash

# Comprehensive verification script for PowerDNS module

echo "=== PowerDNS Module Verification ==="
echo ""

# 1. Check module files
echo "1. Checking module files..."
SETUP_FILE="/usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm"
REMOTE_FILE="/usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm"

if [ -f "$SETUP_FILE" ]; then
    echo "   ✅ Setup module exists: $SETUP_FILE"
    ls -lh "$SETUP_FILE" | awk '{print "      Permissions: " $1 " Owner: " $3 ":" $4 " Size: " $5}'
else
    echo "   ❌ Setup module NOT found: $SETUP_FILE"
fi

if [ -f "$REMOTE_FILE" ]; then
    echo "   ✅ Remote module exists: $REMOTE_FILE"
    ls -lh "$REMOTE_FILE" | awk '{print "      Permissions: " $1 " Owner: " $3 ":" $4 " Size: " $5}'
else
    echo "   ❌ Remote module NOT found: $REMOTE_FILE"
fi

echo ""

# 2. Check if module can be loaded
echo "2. Testing module loading..."
if [ -f "/usr/local/cpanel/3rdparty/bin/perl" ]; then
    CPANEL_PERL="/usr/local/cpanel/3rdparty/bin/perl"
else
    CPANEL_PERL="/usr/bin/perl"
fi

# Test Setup module
echo "   Testing Setup module..."
if $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e 'use Cpanel::NameServer::Setup::Remote::PowerDNS; print "OK\n";' 2>&1 | grep -q "OK"; then
    echo "      ✅ Setup module loads successfully"
else
    ERROR_OUTPUT=$($CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e 'use Cpanel::NameServer::Setup::Remote::PowerDNS; print "OK\n";' 2>&1)
    if echo "$ERROR_OUTPUT" | grep -q "Can't locate"; then
        echo "      ⚠️  Setup module has dependency issues (may be OK in cPanel context)"
        echo "      Error: $(echo "$ERROR_OUTPUT" | head -1)"
    else
        echo "      ⚠️  Setup module loading issue:"
        echo "      $(echo "$ERROR_OUTPUT" | head -3 | sed 's/^/         /')"
    fi
fi

# Test Remote module
echo "   Testing Remote module..."
if $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e 'use Cpanel::NameServer::Remote::PowerDNS; print "OK\n";' 2>&1 | grep -q "OK"; then
    echo "      ✅ Remote module loads successfully"
else
    ERROR_OUTPUT=$($CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e 'use Cpanel::NameServer::Remote::PowerDNS; print "OK\n";' 2>&1)
    if echo "$ERROR_OUTPUT" | grep -q "Can't locate"; then
        echo "      ⚠️  Remote module has dependency issues (may be OK in cPanel context)"
        echo "      Error: $(echo "$ERROR_OUTPUT" | head -1)"
    else
        echo "      ⚠️  Remote module loading issue:"
        echo "      $(echo "$ERROR_OUTPUT" | head -3 | sed 's/^/         /')"
    fi
fi

echo ""

# 3. Check get_config method
echo "3. Testing get_config method..."
CONFIG_OUTPUT=$($CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e 'use Cpanel::NameServer::Setup::Remote::PowerDNS; my $config = Cpanel::NameServer::Setup::Remote::PowerDNS::get_config(); if (ref($config) eq "ARRAY") { print "OK - Returns array with " . scalar(@$config) . " fields\n"; } else { print "WARNING - Returns: " . (ref($config) || "scalar") . "\n"; }' 2>&1)

if echo "$CONFIG_OUTPUT" | grep -q "OK"; then
    echo "   ✅ get_config method works"
    echo "   $CONFIG_OUTPUT" | sed 's/^/      /'
else
    echo "   ⚠️  get_config method issue:"
    echo "$CONFIG_OUTPUT" | sed 's/^/      /'
fi

echo ""

# 4. Check dnsadmin dormant status
echo "4. Checking dnsadmin dormant status..."
if [ -f "/var/cpanel/cpanel.config" ]; then
    DORMANT=$(grep "^dormant_services=" /var/cpanel/cpanel.config 2>/dev/null | cut -d'=' -f2)
    if echo "$DORMANT" | grep -qi "dnsadmin"; then
        echo "   ❌ dnsadmin is in dormant services!"
        echo "      Current dormant_services: $DORMANT"
        echo "      Action: Go to WHM >> Tweak Settings >> Dormant services"
        echo "      Uncheck 'dnsadmin' and click Save"
    else
        echo "   ✅ dnsadmin is NOT in dormant services"
        if [ -n "$DORMANT" ]; then
            echo "      Current dormant_services: $DORMANT"
        else
            echo "      No dormant services configured"
        fi
    fi
else
    echo "   ⚠️  Could not check dormant status (cpanel.config not found)"
fi

echo ""

# 5. Check for other DNS cluster backends (for comparison)
echo "5. Checking for other DNS cluster modules..."
if [ -d "/usr/local/cpanel/Cpanel/NameServer/Setup/Remote" ]; then
    OTHER_MODULES=$(ls -1 /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/*.pm 2>/dev/null | grep -v PowerDNS | xargs -n1 basename | sed 's/\.pm$//' | tr '\n' ' ')
    if [ -n "$OTHER_MODULES" ]; then
        echo "   Found other backend modules: $OTHER_MODULES"
        echo "   (This is good - means the directory is being scanned)"
    else
        echo "   ⚠️  No other backend modules found (PowerDNS might be the only one)"
    fi
else
    echo "   ❌ Setup/Remote directory not found!"
fi

echo ""

# 6. Check config file
echo "6. Checking PowerDNS config file..."
CONFIG_FILE="/var/cpanel/cluster/root/config/powerdns"
if [ -f "$CONFIG_FILE" ]; then
    echo "   ✅ Config file exists: $CONFIG_FILE"
    if [ -r "$CONFIG_FILE" ]; then
        echo "   Contents:"
        cat "$CONFIG_FILE" | sed 's/apikey=.*/apikey=***HIDDEN***/' | sed 's/pass=.*/pass=***HIDDEN***/' | sed 's/^/      /'
    fi
else
    echo "   ⚠️  Config file not found (this is OK if you haven't added the server yet)"
fi

echo ""

# 7. Check recent cPanel error logs
echo "7. Checking recent cPanel error logs for PowerDNS-related errors..."
if [ -f "/usr/local/cpanel/logs/error_log" ]; then
    RECENT_ERRORS=$(grep -i "powerdns\|PowerDNS" /usr/local/cpanel/logs/error_log 2>/dev/null | tail -5)
    if [ -n "$RECENT_ERRORS" ]; then
        echo "   Found recent PowerDNS-related errors:"
        echo "$RECENT_ERRORS" | sed 's/^/      /'
    else
        echo "   ✅ No recent PowerDNS-related errors found"
    fi
else
    echo "   ⚠️  Error log not found"
fi

echo ""

# 8. Summary and recommendations
echo "=== Summary and Recommendations ==="
echo ""
echo "If all checks pass but PowerDNS still doesn't appear in WHM:"
echo ""
echo "1. Clear cPanel cache (if script exists):"
echo "   /usr/local/cpanel/scripts/update_cpanel_cache"
echo ""
echo "2. Restart cPanel:"
echo "   /scripts/restartsrv_cpsrvd"
echo ""
echo "3. Wait 30-60 seconds, then:"
echo "   - Go to: WHM >> Clusters >> DNS Cluster"
echo "   - Click 'Add a DNS Server'"
echo "   - Check if 'PowerDNS' appears in the Backend Type dropdown"
echo ""
echo "4. If PowerDNS appears in dropdown:"
echo "   - Click 'Configure'"
echo "   - Fill in API URL and key"
echo "   - Click 'Submit'"
echo ""
echo "5. If PowerDNS does NOT appear in dropdown:"
echo "   - Verify dnsadmin is NOT dormant (see step 4 above)"
echo "   - Check that module files have correct permissions (644)"
echo "   - Review error logs: tail -f /usr/local/cpanel/logs/error_log"
echo "   - Try accessing WHM >> Clusters >> DNS Cluster while watching logs"
echo ""

