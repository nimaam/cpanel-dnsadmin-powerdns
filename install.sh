#!/bin/bash

# Installation script for cPanel dnsadmin PowerDNS Plugin

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

# Verify Perl syntax
echo "Verifying Perl syntax..."
if perl -c "$SETUP_TARGET/PowerDNS.pm" 2>/dev/null; then
    echo "  ✓ Setup module syntax OK"
else
    echo "  ✗ Error: Setup module has syntax errors"
    exit 1
fi

if perl -c "$REMOTE_TARGET/PowerDNS.pm" 2>/dev/null; then
    echo "  ✓ Remote module syntax OK"
else
    echo "  ✗ Error: Remote module has syntax errors"
    exit 1
fi

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






