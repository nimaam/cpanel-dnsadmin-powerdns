#!/bin/bash

# Installation script for External PDNS cPanel dnsadmin module
# This script installs the External PDNS module to the cPanel system

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    exit 1
fi

# Check if cPanel is installed
if [ ! -d "/usr/local/cpanel" ]; then
    echo -e "${RED}Error: cPanel is not installed on this system${NC}"
    exit 1
fi

echo -e "${GREEN}Installing External PDNS module for cPanel dnsadmin...${NC}"

# Define source and destination paths
CPANEL_BASE="/usr/local/cpanel"
SETUP_SOURCE="cPanel-dnsadmin/Setup/Remote/ExternalPDNS.pm"
REMOTE_SOURCE="cPanel-dnsadmin/Remote/ExternalPDNS.pm"
SETUP_DEST="$CPANEL_BASE/Cpanel/NameServer/Setup/Remote/ExternalPDNS.pm"
REMOTE_DEST="$CPANEL_BASE/Cpanel/NameServer/Remote/ExternalPDNS.pm"

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Check if source files exist
if [ ! -f "$SCRIPT_DIR/$SETUP_SOURCE" ]; then
    echo -e "${RED}Error: Setup module not found at $SCRIPT_DIR/$SETUP_SOURCE${NC}"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/$REMOTE_SOURCE" ]; then
    echo -e "${RED}Error: Remote module not found at $SCRIPT_DIR/$REMOTE_SOURCE${NC}"
    exit 1
fi

# Create destination directories if they don't exist
mkdir -p "$(dirname "$SETUP_DEST")"
mkdir -p "$(dirname "$REMOTE_DEST")"

# Copy files
echo -e "${YELLOW}Copying Setup module...${NC}"
cp "$SCRIPT_DIR/$SETUP_SOURCE" "$SETUP_DEST"
chmod 644 "$SETUP_DEST"

echo -e "${YELLOW}Copying Remote module...${NC}"
cp "$SCRIPT_DIR/$REMOTE_SOURCE" "$REMOTE_DEST"
chmod 644 "$REMOTE_DEST"

# Verify installation
if [ -f "$SETUP_DEST" ] && [ -f "$REMOTE_DEST" ]; then
    echo -e "${GREEN}✓ External PDNS module installed successfully!${NC}"
    echo ""
    echo -e "${GREEN}Installation complete.${NC}"
    echo ""
    echo "Files installed:"
    echo "  - $SETUP_DEST"
    echo "  - $REMOTE_DEST"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Go to WHM → DNS Clustering"
    echo "2. Click 'Add Node'"
    echo "3. Select 'External PDNS' as the node type"
    echo "4. Enter your PowerDNS API URL, API key, server ID, and nameservers"
    echo "5. Configure NS record handling (force/ensure/default)"
    echo ""
    echo -e "${GREEN}The module is now ready to use!${NC}"
else
    echo -e "${RED}Error: Installation verification failed${NC}"
    exit 1
fi

