#!/bin/bash

# Check DNS cluster status and configuration

echo "=== DNS Cluster Status Check ==="
echo ""

# Check config files
echo "1. Checking PowerDNS config files..."
find /var/cpanel/cluster -name "powerdns" -type f 2>/dev/null | while read config; do
    echo "   Found: $config"
    if [ -r "$config" ]; then
        echo "   Contents:"
        cat "$config" | sed 's/apikey=.*/apikey=***HIDDEN***/' | sed 's/pass=.*/pass=***HIDDEN***/' | sed 's/^/      /'
    fi
done

if [ -z "$(find /var/cpanel/cluster -name "powerdns" -type f 2>/dev/null)" ]; then
    echo "   ⚠️  No PowerDNS config files found"
fi

echo ""

# Check cluster directory structure
echo "2. Checking cluster directory structure..."
if [ -d "/var/cpanel/cluster" ]; then
    echo "   Cluster directory exists"
    echo "   Subdirectories:"
    ls -ld /var/cpanel/cluster/*/ 2>/dev/null | awk '{print "      " $9}' || echo "      (none)"
else
    echo "   ⚠️  Cluster directory not found"
fi

echo ""

# Check if there are other backend configs for comparison
echo "3. Checking other backend configurations (for comparison)..."
find /var/cpanel/cluster -type f -name "*" 2>/dev/null | grep -v powerdns | head -5 | while read config; do
    echo "   Found: $config"
done

echo ""

# Check cPanel cluster database/files
echo "4. Checking cPanel cluster registration..."
if [ -f "/var/cpanel/cluster/config" ]; then
    echo "   Cluster config file exists:"
    cat /var/cpanel/cluster/config | head -10 | sed 's/^/      /'
else
    echo "   ⚠️  Cluster config file not found at /var/cpanel/cluster/config"
fi

echo ""

# Check WHM API for cluster info
echo "5. Checking WHM API for DNS cluster info..."
/usr/local/cpanel/bin/whmapi1 list_dns_cluster_backends 2>&1 | grep -i -E "powerdns|backend|function" | head -10 || echo "   (no relevant output)"

echo ""

# Check if we need to refresh/rebuild cluster
echo "6. Recommendations:"
echo "   - Clear cPanel cache: /usr/local/cpanel/scripts/update_cpanel_cache"
echo "   - Restart cPanel: /scripts/restartsrv_cpsrvd"
echo "   - Try accessing: WHM >> Clusters >> DNS Cluster"
echo "   - The server might need to be added through the web interface"
echo "   - Config file exists, but cPanel may need to 'discover' it"
echo ""





