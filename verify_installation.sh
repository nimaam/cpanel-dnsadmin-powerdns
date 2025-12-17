#!/bin/bash

# Verification script for PowerDNS cPanel dnsadmin plugin
# Run this on your cPanel server as root

set -e

echo "=== PowerDNS cPanel Plugin Verification ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Find cPanel Perl
if [ -f "/usr/local/cpanel/3rdparty/bin/perl" ]; then
    CPANEL_PERL="/usr/local/cpanel/3rdparty/bin/perl"
elif [ -f "/usr/bin/perl" ]; then
    CPANEL_PERL="/usr/bin/perl"
    # Try to set PERL5LIB for cPanel modules
    export PERL5LIB="/usr/local/cpanel/Cpanel:$PERL5LIB"
else
    echo "Error: Cannot find Perl"
    exit 1
fi

echo "Using Perl: $CPANEL_PERL"
echo ""

# Define file paths
SETUP_FILE="/usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm"
REMOTE_FILE="/usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm"

# Check if files exist
echo "1. Checking file existence..."
if [ -f "$SETUP_FILE" ]; then
    echo "   ✓ Setup module exists: $SETUP_FILE"
else
    echo "   ✗ Setup module NOT found: $SETUP_FILE"
    exit 1
fi

if [ -f "$REMOTE_FILE" ]; then
    echo "   ✓ Remote module exists: $REMOTE_FILE"
else
    echo "   ✗ Remote module NOT found: $REMOTE_FILE"
    exit 1
fi

echo ""

# Check file permissions
echo "2. Checking file permissions..."
SETUP_PERMS=$(stat -c "%a" "$SETUP_FILE" 2>/dev/null || stat -f "%OLp" "$SETUP_FILE" 2>/dev/null)
REMOTE_PERMS=$(stat -c "%a" "$REMOTE_FILE" 2>/dev/null || stat -f "%OLp" "$REMOTE_FILE" 2>/dev/null)

if [ "$SETUP_PERMS" = "644" ] || [ "$SETUP_PERMS" = "0644" ]; then
    echo "   ✓ Setup module permissions OK: $SETUP_PERMS"
else
    echo "   ⚠️  Fixing Setup module permissions (current: $SETUP_PERMS, setting to 644)..."
    chmod 644 "$SETUP_FILE"
    echo "   ✓ Permissions fixed"
fi

if [ "$REMOTE_PERMS" = "644" ] || [ "$REMOTE_PERMS" = "0644" ]; then
    echo "   ✓ Remote module permissions OK: $REMOTE_PERMS"
else
    echo "   ⚠️  Fixing Remote module permissions (current: $REMOTE_PERMS, setting to 644)..."
    chmod 644 "$REMOTE_FILE"
    echo "   ✓ Permissions fixed"
fi

echo ""

# Check Perl syntax with cPanel Perl
echo "3. Checking Perl syntax with cPanel Perl..."
echo "   (This may show warnings about missing modules - that's OK if files are in correct location)"
echo ""

# Set PERL5LIB to include cPanel directories
export PERL5LIB="/usr/local/cpanel/Cpanel:/usr/local/cpanel:$PERL5LIB"

# Try to check syntax - we expect it might fail due to dependencies, but we can check basic syntax
echo "   Checking Setup module..."
if $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -c "$SETUP_FILE" 2>&1 | grep -q "syntax OK"; then
    echo "   ✓ Setup module syntax OK"
elif $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -c "$SETUP_FILE" 2>&1 | grep -q "Can't locate"; then
    echo "   ⚠️  Setup module: Cannot verify (missing dependencies - this is OK if cPanel is running)"
    echo "      The module will be loaded by cPanel's own Perl with proper @INC"
else
    echo "   ✗ Setup module syntax errors:"
    $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -c "$SETUP_FILE" 2>&1 | head -5
fi

echo ""
echo "   Checking Remote module..."
if $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -c "$REMOTE_FILE" 2>&1 | grep -q "syntax OK"; then
    echo "   ✓ Remote module syntax OK"
elif $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -c "$REMOTE_FILE" 2>&1 | grep -q "Can't locate"; then
    echo "   ⚠️  Remote module: Cannot verify (missing dependencies - this is OK if cPanel is running)"
    echo "      The module will be loaded by cPanel's own Perl with proper @INC"
else
    echo "   ✗ Remote module syntax errors:"
    $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -c "$REMOTE_FILE" 2>&1 | head -5
fi

echo ""

# Check for other backend modules
echo "4. Checking for other backend modules (for comparison)..."
if [ -d "/usr/local/cpanel/Cpanel/NameServer/Setup/Remote" ]; then
    echo "   Available backend modules in Setup/Remote:"
    ls -lh /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/*.pm 2>/dev/null | awk '{print "      " $9 " (" $5 ")"}' || echo "      (none found)"
fi

echo ""

# Check cPanel error logs for PowerDNS-related errors
echo "5. Checking recent cPanel error logs for PowerDNS/dnsadmin errors..."
if [ -f "/usr/local/cpanel/logs/error_log" ]; then
    echo "   Recent relevant errors (last 20 lines):"
    grep -i "powerdns\|dnsadmin.*powerdns\|nameserver.*powerdns" /usr/local/cpanel/logs/error_log 2>/dev/null | tail -5 || echo "      (no PowerDNS-related errors found)"
else
    echo "   ⚠️  Error log not found"
fi

echo ""

# Check dnsadmin dormant status
echo "6. Checking dnsadmin dormant service status..."
if [ -f "/var/cpanel/cpanel.config" ]; then
    DORMANT=$(grep "^dnsadmin=" /var/cpanel/cpanel.config 2>/dev/null | cut -d= -f2)
    if [ "$DORMANT" = "0" ]; then
        echo "   ✓ dnsadmin is NOT dormant (enabled)"
    elif [ -z "$DORMANT" ]; then
        echo "   ✓ dnsadmin is NOT dormant (not in config = enabled)"
    else
        echo "   ✗ dnsadmin IS dormant (value: $DORMANT)"
        echo "      You must disable this in: WHM >> Server Configuration >> Tweak Settings"
    fi
else
    echo "   ⚠️  Cannot check dormant status (config file not found)"
fi

echo ""

# Final recommendations
echo "=== Next Steps ==="
echo ""
echo "If PowerDNS is still not appearing in the backend dropdown:"
echo ""
echo "1. Clear cPanel cache:"
echo "   /usr/local/cpanel/scripts/update_cpanel_cache"
echo ""
echo "2. Restart cPanel services:"
echo "   /scripts/restartsrv_cpsrvd"
echo ""
echo "3. Check cPanel error log in real-time while accessing DNS Cluster:"
echo "   tail -f /usr/local/cpanel/logs/error_log"
echo "   (Then try to access: WHM >> Clusters >> DNS Cluster >> Add a DNS Server)"
echo ""
echo "4. Verify the module can be loaded by cPanel:"
echo "   /usr/local/cpanel/3rdparty/bin/perl -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e 'use Cpanel::NameServer::Setup::Remote::PowerDNS; print \"OK\\n\";'"
echo ""
echo "5. Check if there are any SELinux or AppArmor restrictions:"
echo "   (if applicable on your system)"
echo ""
echo "Done!"
echo ""






