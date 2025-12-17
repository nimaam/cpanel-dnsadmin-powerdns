#!/bin/bash

# Check what cPanel actually sees when trying to add PowerDNS server

echo "=== Checking cPanel Error Logs for PowerDNS ==="
echo ""

echo "1. Recent PowerDNS-related errors (last 50 lines):"
tail -100 /usr/local/cpanel/logs/error_log 2>/dev/null | grep -i -E "powerdns|dnsadmin.*powerdns|setup.*powerdns" | tail -20 || echo "   (no PowerDNS errors found)"

echo ""
echo "2. Recent dnsadmin setup errors:"
tail -100 /usr/local/cpanel/logs/error_log 2>/dev/null | grep -i -E "dnsadmin.*setup|setup.*dnsadmin|clustering.*setup" | tail -10 || echo "   (no setup errors found)"

echo ""
echo "3. Recent ACL or permission errors:"
tail -100 /usr/local/cpanel/logs/error_log 2>/dev/null | grep -i -E "acl|permission|clustering.*acl" | tail -10 || echo "   (no ACL errors found)"

echo ""
echo "=== Instructions ==="
echo "1. Keep this script running:"
echo "   tail -f /usr/local/cpanel/logs/error_log | grep -i powerdns"
echo ""
echo "2. In another terminal/browser, try adding the PowerDNS server"
echo ""
echo "3. Watch for any errors that appear"
echo ""





