#!/bin/bash

# Troubleshooting script for PowerDNS cPanel dnsadmin plugin

echo "=== PowerDNS cPanel Plugin Troubleshooting ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Warning: Some checks require root access"
    echo ""
fi

# Check file locations
echo "1. Checking file locations..."
SETUP_FILE="/usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm"
REMOTE_FILE="/usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm"

if [ -f "$SETUP_FILE" ]; then
    echo "   ✓ Setup module found: $SETUP_FILE"
    ls -lh "$SETUP_FILE"
else
    echo "   ✗ Setup module NOT found: $SETUP_FILE"
fi

if [ -f "$REMOTE_FILE" ]; then
    echo "   ✓ Remote module found: $REMOTE_FILE"
    ls -lh "$REMOTE_FILE"
else
    echo "   ✗ Remote module NOT found: $REMOTE_FILE"
fi

echo ""

# Check file permissions
echo "2. Checking file permissions..."
if [ -f "$SETUP_FILE" ]; then
    PERMS=$(stat -c "%a" "$SETUP_FILE" 2>/dev/null || stat -f "%OLp" "$SETUP_FILE" 2>/dev/null)
    if [ "$PERMS" = "644" ] || [ "$PERMS" = "0644" ]; then
        echo "   ✓ Setup module permissions OK: $PERMS"
    else
        echo "   ⚠️  Setup module permissions: $PERMS (expected: 644)"
    fi
fi

if [ -f "$REMOTE_FILE" ]; then
    PERMS=$(stat -c "%a" "$REMOTE_FILE" 2>/dev/null || stat -f "%OLp" "$REMOTE_FILE" 2>/dev/null)
    if [ "$PERMS" = "644" ] || [ "$PERMS" = "0644" ]; then
        echo "   ✓ Remote module permissions OK: $PERMS"
    else
        echo "   ⚠️  Remote module permissions: $PERMS (expected: 644)"
    fi
fi

echo ""

# Check Perl syntax (if cPanel Perl is available)
echo "3. Checking Perl syntax..."
if command -v /usr/local/cpanel/3rdparty/bin/perl &> /dev/null; then
    CPANEL_PERL="/usr/local/cpanel/3rdparty/bin/perl"
elif [ -f "/usr/local/cpanel/3rdparty/bin/perl" ]; then
    CPANEL_PERL="/usr/local/cpanel/3rdparty/bin/perl"
else
    CPANEL_PERL="perl"
fi

if [ -f "$SETUP_FILE" ]; then
    if $CPANEL_PERL -c "$SETUP_FILE" 2>&1 | grep -q "syntax OK"; then
        echo "   ✓ Setup module syntax OK"
    else
        echo "   ✗ Setup module syntax errors:"
        $CPANEL_PERL -c "$SETUP_FILE" 2>&1 | grep -v "^$"
    fi
fi

if [ -f "$REMOTE_FILE" ]; then
    if $CPANEL_PERL -c "$REMOTE_FILE" 2>&1 | grep -q "syntax OK"; then
        echo "   ✓ Remote module syntax OK"
    else
        echo "   ✗ Remote module syntax errors:"
        $CPANEL_PERL -c "$REMOTE_FILE" 2>&1 | grep -v "^$"
    fi
fi

echo ""

# Check for other backend modules (for comparison)
echo "4. Checking for other backend modules..."
if [ -d "/usr/local/cpanel/Cpanel/NameServer/Setup/Remote" ]; then
    echo "   Available backend modules:"
    ls -1 /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/*.pm 2>/dev/null | while read file; do
        basename "$file" .pm
    done
fi

echo ""

# Check cPanel error logs
echo "5. Checking recent cPanel error logs..."
if [ -f "/usr/local/cpanel/logs/error_log" ] && [ -r "/usr/local/cpanel/logs/error_log" ]; then
    echo "   Recent errors related to PowerDNS or dnsadmin:"
    tail -50 /usr/local/cpanel/logs/error_log | grep -i "powerdns\|dnsadmin\|nameserver" | tail -10 || echo "   (no relevant errors found)"
else
    echo "   ⚠️  Cannot read error log (may need root access)"
fi

echo ""

# Check dnsadmin logs
echo "6. Checking dnsadmin logs..."
if [ -f "/var/log/dnsadmin_log" ] && [ -r "/var/log/dnsadmin_log" ]; then
    echo "   Recent dnsadmin log entries:"
    tail -20 /var/log/dnsadmin_log | tail -5 || echo "   (no recent entries)"
else
    echo "   ⚠️  Cannot read dnsadmin log (may need root access)"
fi

echo ""

# Check if dnsadmin is disabled in dormant services
echo "7. Checking dnsadmin dormant service status..."
if [ -f "/var/cpanel/cpanel.config" ]; then
    DORMANT=$(grep "^dnsadmin=" /var/cpanel/cpanel.config 2>/dev/null | cut -d= -f2)
    if [ "$DORMANT" = "0" ] || [ -z "$DORMANT" ]; then
        echo "   ✓ dnsadmin is NOT dormant (enabled)"
    else
        echo "   ⚠️  dnsadmin may be dormant (check WHM Tweak Settings)"
    fi
else
    echo "   ⚠️  Cannot check dormant status"
fi

echo ""

# Recommendations
echo "=== Recommendations ==="
echo ""
echo "If PowerDNS is not appearing in the backend dropdown:"
echo ""
echo "1. Verify files are installed correctly:"
echo "   - Setup: $SETUP_FILE"
echo "   - Remote: $REMOTE_FILE"
echo ""
echo "2. Check file permissions (should be 644):"
echo "   chmod 644 $SETUP_FILE"
echo "   chmod 644 $REMOTE_FILE"
echo ""
echo "3. Verify Perl syntax on the cPanel server:"
echo "   /usr/local/cpanel/3rdparty/bin/perl -c $SETUP_FILE"
echo "   /usr/local/cpanel/3rdparty/bin/perl -c $REMOTE_FILE"
echo ""
echo "4. Clear cPanel cache and restart services:"
echo "   /scripts/restartsrv_cpsrvd"
echo "   /usr/local/cpanel/scripts/update_cpanel_cache"
echo ""
echo "5. Check cPanel error logs for module loading errors:"
echo "   tail -f /usr/local/cpanel/logs/error_log"
echo ""
echo "6. Ensure dnsadmin is NOT in dormant services:"
echo "   WHM >> Server Configuration >> Tweak Settings"
echo "   Uncheck 'dnsadmin' in Dormant services"
echo ""
echo "7. Try accessing DNS Cluster page with browser cache cleared"
echo ""

