#!/bin/bash

# Script to check for PowerDNS errors even when dnsadmin might be disabled

echo "=== PowerDNS Error Checker ==="
echo ""

# Check cPanel error log
echo "1. Checking cPanel error log for PowerDNS errors..."
if [ -f "/usr/local/cpanel/logs/error_log" ]; then
    echo "   Recent PowerDNS-related errors:"
    grep -i "powerdns\|nameserver.*powerdns\|dnsadmin.*powerdns" /usr/local/cpanel/logs/error_log 2>/dev/null | tail -20 || echo "   (no PowerDNS errors found)"
else
    echo "   ⚠️  Error log not found"
fi

echo ""

# Check dnsadmin log (if accessible)
echo "2. Checking dnsadmin log..."
if [ -f "/var/log/dnsadmin_log" ] && [ -r "/var/log/dnsadmin_log" ]; then
    echo "   Recent dnsadmin entries:"
    tail -20 /var/log/dnsadmin_log 2>/dev/null || echo "   (cannot read dnsadmin log)"
else
    echo "   ⚠️  dnsadmin log not accessible (may be normal if dnsadmin is disabled)"
fi

echo ""

# Check for config file
echo "3. Checking for PowerDNS config files..."
if [ -d "/var/cpanel/cluster" ]; then
    find /var/cpanel/cluster -name "powerdns" -type f 2>/dev/null | while read config; do
        echo "   Found config: $config"
        if [ -r "$config" ]; then
            echo "   Contents:"
            cat "$config" | sed 's/pass=.*/pass=***HIDDEN***/' | head -10
        fi
    done
    if [ -z "$(find /var/cpanel/cluster -name "powerdns" -type f 2>/dev/null)" ]; then
        echo "   (no PowerDNS config files found)"
    fi
else
    echo "   ⚠️  Cluster directory not found"
fi

echo ""

# Check dnsadmin dormant status
echo "4. Checking dnsadmin dormant status..."
if [ -f "/var/cpanel/cpanel.config" ]; then
    DORMANT=$(grep "^dnsadmin=" /var/cpanel/cpanel.config 2>/dev/null | cut -d= -f2)
    if [ "$DORMANT" = "0" ]; then
        echo "   ✓ dnsadmin is NOT dormant (enabled)"
    elif [ -z "$DORMANT" ]; then
        echo "   ✓ dnsadmin is NOT dormant (not in config = enabled)"
    else
        echo "   ⚠️  dnsadmin IS dormant (value: $DORMANT)"
        echo "      Note: dnsadmin should be enabled for DNS cluster to work"
    fi
else
    echo "   ⚠️  Cannot check dormant status"
fi

echo ""

# Check module files
echo "5. Checking module files..."
SETUP_FILE="/usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm"
REMOTE_FILE="/usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm"

if [ -f "$SETUP_FILE" ]; then
    echo "   ✓ Setup module exists"
    ls -lh "$SETUP_FILE" | awk '{print "      " $9 " (" $5 ", " $1 ")"}'
else
    echo "   ✗ Setup module NOT found"
fi

if [ -f "$REMOTE_FILE" ]; then
    echo "   ✓ Remote module exists"
    ls -lh "$REMOTE_FILE" | awk '{print "      " $9 " (" $5 ", " $1 ")"}'
else
    echo "   ✗ Remote module NOT found"
fi

echo ""

# Check recent system logs
echo "6. Checking system logs for PowerDNS..."
if command -v journalctl &> /dev/null; then
    echo "   Recent systemd journal entries:"
    journalctl -u cpanel -n 20 2>/dev/null | grep -i powerdns || echo "   (no PowerDNS entries in journal)"
fi

echo ""
echo "=== To see errors in real-time ==="
echo "Run this command and then try to add the PowerDNS server:"
echo "  tail -f /usr/local/cpanel/logs/error_log | grep -i powerdns"
echo ""





