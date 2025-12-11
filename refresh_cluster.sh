#!/bin/bash

# Script to refresh cPanel DNS cluster cache and services

echo "=== Refreshing cPanel DNS Cluster ==="
echo ""

# 1. Clear cPanel cache
echo "1. Clearing cPanel cache..."
if [ -f "/usr/local/cpanel/scripts/update_cpanel_cache" ]; then
    /usr/local/cpanel/scripts/update_cpanel_cache
    echo "   ✅ Cache cleared"
else
    echo "   ⚠️  Cache script not found"
fi

echo ""

# 2. Restart cPanel services
echo "2. Restarting cPanel services..."
if [ -f "/scripts/restartsrv_cpsrvd" ]; then
    /scripts/restartsrv_cpsrvd
    echo "   ✅ cPanel service restarted"
else
    echo "   ⚠️  Restart script not found"
fi

echo ""

# 3. Check if config file exists
echo "3. Verifying PowerDNS config file..."
CONFIG_FILE="/var/cpanel/cluster/root/config/powerdns"
if [ -f "$CONFIG_FILE" ]; then
    echo "   ✅ Config file exists: $CONFIG_FILE"
    echo "   Contents:"
    cat "$CONFIG_FILE" | sed 's/apikey=.*/apikey=***HIDDEN***/' | sed 's/pass=.*/pass=***HIDDEN***/' | sed 's/^/      /'
else
    echo "   ⚠️  Config file not found: $CONFIG_FILE"
    echo "   You may need to add the server through the web interface first"
fi

echo ""

# 4. Check dnsadmin status
echo "4. Checking dnsadmin status..."
if [ -f "/usr/local/cpanel/bin/whmapi1" ]; then
    echo "   Checking if dnsadmin is dormant..."
    /usr/local/cpanel/bin/whmapi1 get_tweak setting=dormant_services 2>&1 | grep -i dnsadmin || echo "   (Could not check dormant status)"
fi

echo ""

# 5. List available backends
echo "5. Checking available DNS cluster backends..."
if [ -f "/usr/local/cpanel/bin/whmapi1" ]; then
    /usr/local/cpanel/bin/whmapi1 list_dns_cluster_backends 2>&1 | grep -i -E "powerdns|backend|function" | head -10 || echo "   (No relevant output)"
fi

echo ""

# 6. Instructions
echo "=== Next Steps ==="
echo ""
echo "After running this script:"
echo "1. Wait 30-60 seconds for services to restart"
echo "2. Go to: WHM >> Clusters >> DNS Cluster"
echo "3. Click 'Add a DNS Server'"
echo "4. Select 'PowerDNS' from the Backend Type dropdown"
echo "5. Click 'Configure'"
echo ""
echo "If PowerDNS doesn't appear in the dropdown:"
echo "- Verify the module files are installed correctly:"
echo "  ls -la /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm"
echo "  ls -la /usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm"
echo "- Check that dnsadmin is NOT in dormant services"
echo "- Run: ./check_cluster_status.sh"
echo ""
echo "If the config file already exists but server doesn't show:"
echo "- You may need to add it through the web interface anyway"
echo "- The web interface will call the setup method again"
echo "- This is normal - cPanel needs to register it through its UI"
echo ""

