#!/bin/bash

# Script to manually test DNS cluster synchronization
# This script demonstrates how to trigger synchronization manually

echo "=== Manual DNS Cluster Synchronization Test ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "⚠️  This script should be run as root for full functionality"
    echo ""
fi

# Method 1: Using WHMAPI1 to trigger sync
echo "Method 1: Using WHMAPI1 to synchronize DNS cluster"
echo "---------------------------------------------------"
echo ""
echo "To synchronize all zones to a specific DNS server node:"
echo ""
echo "  /usr/local/cpanel/bin/whmapi1 dnscluster_sync_zones \\"
echo "    dnspeer=<dns_server_hostname>"
echo ""
echo "Example:"
echo "  /usr/local/cpanel/bin/whmapi1 dnscluster_sync_zones dnspeer=powerdns.example.com"
echo ""

# Get list of DNS cluster nodes
echo "Available DNS cluster nodes:"
if [ -f "/usr/local/cpanel/bin/whmapi1" ]; then
    /usr/local/cpanel/bin/whmapi1 list_dns_cluster_nodes 2>/dev/null | grep -E "hostname|name|module" | head -20 || echo "  (Could not retrieve node list)"
else
    echo "  whmapi1 not found"
fi
echo ""

# Method 2: Direct Perl test (requires understanding of dnsadmin internals)
echo "Method 2: Direct module test (for debugging)"
echo "---------------------------------------------------"
echo ""
echo "To test the synczones method directly, you can use:"
echo ""
echo "  /usr/local/cpanel/3rdparty/bin/perl -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e '"
echo "    use Cpanel::NameServer::Remote::PowerDNS;"
echo "    # Load config and create instance"
echo "    # Then call synczones method"
echo "  '"
echo ""
echo "Note: This requires setting up the module instance with proper callbacks"
echo ""

# Method 3: Check current sync status
echo "Method 3: Check sync status and queue"
echo "---------------------------------------------------"
echo ""
echo "Check DNS admin queue status:"
if [ -f "/usr/local/cpanel/bin/whmapi1" ]; then
    echo "  /usr/local/cpanel/bin/whmapi1 get_dns_cluster_config"
    /usr/local/cpanel/bin/whmapi1 get_dns_cluster_config 2>/dev/null | head -30 || echo "  (Could not retrieve config)"
else
    echo "  whmapi1 not found"
fi
echo ""

# Method 4: Monitor logs during sync
echo "Method 4: Monitor logs during synchronization"
echo "---------------------------------------------------"
echo ""
echo "To watch what happens during sync, run in another terminal:"
echo ""
echo "  tail -f /usr/local/cpanel/logs/dnsadmin_log"
echo ""
echo "Or if debug mode is enabled:"
echo "  tail -f /usr/local/cpanel/logs/dnsadmin_powerdns_log"
echo ""

# Method 5: Test individual zone sync
echo "Method 5: Sync individual zone (via savezone)"
echo "---------------------------------------------------"
echo ""
echo "Individual zones are synced automatically when changed, but you can"
echo "force a zone update by modifying it in cPanel or using:"
echo ""
echo "  /usr/local/cpanel/bin/whmapi1 dns_mass_edit \\"
echo "    domain=example.com \\"
echo "    action=save"
echo ""

# Current implementation status
echo "=== Current Implementation Status ==="
echo ""
echo "⚠️  IMPORTANT: The current synczones() implementation is a STUB."
echo "   It does NOT actually synchronize zones like SoftLayer/VPSNET do."
echo ""
echo "   Current behavior:"
echo "   - Returns SUCCESS/OK to dnsadmin"
echo "   - Does NOT parse or process zone data"
echo "   - Does NOT call addzoneconf or savezone for each zone"
echo ""
echo "   To implement full synchronization (like SoftLayer/VPSNET):"
echo "   - Parse rawdata containing cpdnszone- entries"
echo "   - For each zone: check if exists, create if needed, save zone data"
echo "   - See: cPanel-Nameserver/Remote/SoftLayer.pm lines 556-589"
echo ""

echo "=== Test Instructions ==="
echo ""
echo "1. Enable debug mode in PowerDNS config:"
echo "   Edit: /var/cpanel/cluster/root/config/powerdns"
echo "   Set: debug=on"
echo ""
echo "2. In one terminal, monitor logs:"
echo "   tail -f /usr/local/cpanel/logs/dnsadmin_powerdns_log"
echo ""
echo "3. In another terminal, trigger sync:"
echo "   /usr/local/cpanel/bin/whmapi1 dnscluster_sync_zones dnspeer=<your-powerdns-host>"
echo ""
echo "4. Watch the log to see what methods are called"
echo ""

echo "=== Done ==="

