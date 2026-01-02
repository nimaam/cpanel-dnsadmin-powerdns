#!/bin/bash

# Installation script for External PDNS cPanel dnsadmin module and DNS Notify Agent
# This script installs the External PDNS module and DNS Notify Agent to the cPanel system

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

echo -e "${GREEN}Installing External PDNS module and DNS Notify Agent for cPanel...${NC}"

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ============================================================================
# Install dnsadmin module
# ============================================================================
echo -e "${YELLOW}Installing dnsadmin module...${NC}"

# Define source and destination paths
CPANEL_BASE="/usr/local/cpanel"
SETUP_SOURCE="cPanel-dnsadmin/Setup/Remote/ExternalPDNS.pm"
REMOTE_SOURCE="cPanel-dnsadmin/Remote/ExternalPDNS.pm"
SETUP_DEST="$CPANEL_BASE/Cpanel/NameServer/Setup/Remote/ExternalPDNS.pm"
REMOTE_DEST="$CPANEL_BASE/Cpanel/NameServer/Remote/ExternalPDNS.pm"

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
echo -e "${YELLOW}  Copying Setup module...${NC}"
cp "$SCRIPT_DIR/$SETUP_SOURCE" "$SETUP_DEST"
chmod 644 "$SETUP_DEST"

echo -e "${YELLOW}  Copying Remote module...${NC}"
cp "$SCRIPT_DIR/$REMOTE_SOURCE" "$REMOTE_DEST"
chmod 644 "$REMOTE_DEST"

# ============================================================================
# Install DNS Notify Agent
# ============================================================================
echo -e "${YELLOW}Installing DNS Notify Agent...${NC}"

AGENT_SOURCE="dns-agent/dns_notify_agent.pl"
AGENT_DEST="/usr/local/cpanel/bin/dns-notify-agent.pl"
SERVICE_SOURCE="dns-agent/dns-notify-agent.service"
SERVICE_DEST="/etc/systemd/system/dns-notify-agent.service"
CONFIG_SOURCE="dns-agent/cpanel-dns-agent.conf.example"
CONFIG_DEST="/etc/cpanel-dns-agent.conf"

# Check if agent files exist
if [ ! -f "$SCRIPT_DIR/$AGENT_SOURCE" ]; then
    echo -e "${YELLOW}  Warning: DNS Notify Agent not found, skipping agent installation${NC}"
else
    # Copy agent script
    echo -e "${YELLOW}  Copying DNS Notify Agent script...${NC}"
    cp "$SCRIPT_DIR/$AGENT_SOURCE" "$AGENT_DEST"
    chmod 755 "$AGENT_DEST"

    # Copy systemd service file
    if [ -f "$SCRIPT_DIR/$SERVICE_SOURCE" ]; then
        echo -e "${YELLOW}  Copying systemd service file...${NC}"
        cp "$SCRIPT_DIR/$SERVICE_SOURCE" "$SERVICE_DEST"
        chmod 644 "$SERVICE_DEST"
    fi

    # Copy example config if config doesn't exist
    if [ ! -f "$CONFIG_DEST" ] && [ -f "$SCRIPT_DIR/$CONFIG_SOURCE" ]; then
        echo -e "${YELLOW}  Creating configuration file...${NC}"
        cp "$SCRIPT_DIR/$CONFIG_SOURCE" "$CONFIG_DEST"
        chmod 644 "$CONFIG_DEST"
        echo -e "${YELLOW}  Please edit $CONFIG_DEST to configure the agent${NC}"
    fi

    # Check if Net::DNS is available
    if ! /usr/local/cpanel/3rdparty/bin/perl -MNet::DNS -e 1 2>/dev/null; then
        echo -e "${YELLOW}  Warning: Net::DNS Perl module not found${NC}"
        echo -e "${YELLOW}  Install it with: cpan Net::DNS${NC}"
    fi
fi

# ============================================================================
# Verify installation
# ============================================================================
echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "Files installed:"
echo "  - $SETUP_DEST"
echo "  - $REMOTE_DEST"

if [ -f "$AGENT_DEST" ]; then
    echo "  - $AGENT_DEST"
    if [ -f "$SERVICE_DEST" ]; then
        echo "  - $SERVICE_DEST"
    fi
    if [ -f "$CONFIG_DEST" ]; then
        echo "  - $CONFIG_DEST"
    fi
fi

echo ""
echo -e "${YELLOW}Next steps for dnsadmin module:${NC}"
echo "1. Go to WHM → DNS Clustering"
echo "2. Click 'Add Node'"
echo "3. Select 'External PDNS' as the node type"
echo "4. Enter your PowerDNS API URL, API key, server ID, and nameservers"
echo "5. Configure NS record handling (force/ensure/default)"

if [ -f "$AGENT_DEST" ]; then
    echo ""
    echo -e "${YELLOW}Next steps for DNS Notify Agent:${NC}"
    echo "1. Edit $CONFIG_DEST and set bind_ip to your specific IP address"
    echo "2. Configure allowed zones (optional)"
    echo "3. Enable and start the service:"
    echo "   systemctl daemon-reload"
    echo "   systemctl enable dns-notify-agent"
    echo "   systemctl start dns-notify-agent"
    echo "4. Configure external PowerDNS to send NOTIFY to this agent's IP:port"
fi

echo ""
echo -e "${GREEN}Installation successful!${NC}"

