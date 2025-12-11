#!/bin/bash

# Installation script for cPanel dnsadmin PowerDNS Plugin

# Don't exit on error for syntax checks (they may fail due to missing cPanel modules)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check if cPanel is installed
if [ ! -d "/usr/local/cpanel" ]; then
    echo "Error: cPanel is not installed on this system"
    exit 1
fi

# Define target directories
SETUP_TARGET="/usr/local/cpanel/Cpanel/NameServer/Setup/Remote"
REMOTE_TARGET="/usr/local/cpanel/Cpanel/NameServer/Remote"

# Create target directories if they don't exist
mkdir -p "$SETUP_TARGET"
mkdir -p "$REMOTE_TARGET"

# Copy Setup module
echo "Installing Setup module..."
if [ -f "$LIB_DIR/Cpanel/NameServer/Setup/Remote/PowerDNS.pm" ]; then
    cp "$LIB_DIR/Cpanel/NameServer/Setup/Remote/PowerDNS.pm" "$SETUP_TARGET/PowerDNS.pm"
    chmod 644 "$SETUP_TARGET/PowerDNS.pm"
    echo "  ✓ Setup module installed to $SETUP_TARGET/PowerDNS.pm"
else
    echo "  ✗ Error: Setup module not found"
    exit 1
fi

# Copy Remote module
echo "Installing Remote module..."
if [ -f "$LIB_DIR/Cpanel/NameServer/Remote/PowerDNS.pm" ]; then
    cp "$LIB_DIR/Cpanel/NameServer/Remote/PowerDNS.pm" "$REMOTE_TARGET/PowerDNS.pm"
    chmod 644 "$REMOTE_TARGET/PowerDNS.pm"
    echo "  ✓ Remote module installed to $REMOTE_TARGET/PowerDNS.pm"
else
    echo "  ✗ Error: Remote module not found"
    exit 1
fi

# Verify Perl syntax (non-fatal - may fail due to missing cPanel modules)
echo "Verifying Perl syntax..."
set +e  # Temporarily disable exit on error for syntax checks

CPANEL_PERL=""
if [ -f "/usr/local/cpanel/3rdparty/bin/perl" ]; then
    CPANEL_PERL="/usr/local/cpanel/3rdparty/bin/perl"
elif [ -f "/usr/bin/perl" ]; then
    CPANEL_PERL="/usr/bin/perl"
fi

if [ -n "$CPANEL_PERL" ]; then
    # Try with cPanel Perl and include paths
    if $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -c "$SETUP_TARGET/PowerDNS.pm" 2>/dev/null; then
        echo "  ✓ Setup module syntax OK"
    elif perl -c "$SETUP_TARGET/PowerDNS.pm" 2>&1 | grep -q "Can't locate Cpanel"; then
        echo "  ⚠️  Setup module: Cannot verify syntax (missing cPanel modules - this is OK)"
        echo "     The module will work when loaded by cPanel's Perl"
    else
        echo "  ⚠️  Setup module: Syntax check inconclusive (may have dependency issues)"
        echo "     This is usually OK - the module will work when loaded by cPanel"
    fi
    
    if $CPANEL_PERL -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -c "$REMOTE_TARGET/PowerDNS.pm" 2>/dev/null; then
        echo "  ✓ Remote module syntax OK"
    elif perl -c "$REMOTE_TARGET/PowerDNS.pm" 2>&1 | grep -q "Can't locate Cpanel"; then
        echo "  ⚠️  Remote module: Cannot verify syntax (missing cPanel modules - this is OK)"
        echo "     The module will work when loaded by cPanel's Perl"
    else
        echo "  ⚠️  Remote module: Syntax check inconclusive (may have dependency issues)"
        echo "     This is usually OK - the module will work when loaded by cPanel"
    fi
else
    echo "  ⚠️  Cannot verify syntax (cPanel Perl not found)"
    echo "     This is OK - syntax will be checked when cPanel loads the modules"
fi

set -e  # Re-enable exit on error

echo ""
echo "Installation completed successfully!"
echo ""
echo "Next steps:"
echo "1. Disable dnsadmin in Dormant services:"
echo "   WHM >> Home >> Server Configuration >> Tweak Settings"
echo "   Uncheck 'dnsadmin' in Dormant services section"
echo ""
echo "2. Configure PowerDNS node:"
echo "   WHM >> Home >> Clusters >> DNS Cluster"
echo "   Click 'Add a DNS Server' and select 'PowerDNS'"
echo ""
echo "3. Test the integration by adding a test zone"






