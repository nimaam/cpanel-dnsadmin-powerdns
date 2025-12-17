#!/bin/bash

# Alternative: Use WHM API to add DNS cluster node
# This uses cPanel's official API

if [ $# -lt 3 ]; then
    echo "Usage: $0 <API_URL> <API_KEY> <USERNAME>"
    echo "Example: $0 http://ns0.ultaservers.com:8081/api/v1 gPJJ4FdWvz4ngNvx root"
    exit 1
fi

API_URL="$1"
API_KEY="$2"
USERNAME="$3"

echo "=== Adding PowerDNS Server via WHM API ==="
echo ""

# Note: WHM API might not have a direct command for this
# But we can check what's available
echo "Checking available WHM API functions..."
/usr/local/cpanel/bin/whmapi1 list_dns_cluster_backends 2>&1 | head -20

echo ""
echo "Note: If the above shows PowerDNS, the backend is registered."
echo "You may need to use the web interface to configure it."
echo ""





