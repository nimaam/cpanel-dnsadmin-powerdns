#!/bin/bash

# Uninstallation script for cPanel dnsadmin PowerDNS Plugin
# This script completely removes all plugin files, configurations, and logs

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo "=== PowerDNS Plugin Uninstallation ==="
echo ""
echo "This will remove:"
echo "  - Module files from /usr/local/cpanel/Cpanel/NameServer/"
echo "  - Configuration files from /var/cpanel/cluster/"
echo "  - Log files from /usr/local/cpanel/logs/"
echo ""

# Ask for confirmation
read -p "Are you sure you want to uninstall the PowerDNS plugin? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Uninstallation cancelled."
    exit 0
fi

echo ""
echo "Starting uninstallation..."
echo ""

# 1. Remove Setup module
echo "1. Removing Setup module..."
SETUP_FILE="/usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm"
if [ -f "$SETUP_FILE" ]; then
    rm -f "$SETUP_FILE"
    echo "   ✅ Removed: $SETUP_FILE"
else
    echo "   ⚠️  Not found: $SETUP_FILE"
fi

# 2. Remove Remote module
echo "2. Removing Remote module..."
REMOTE_FILE="/usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm"
if [ -f "$REMOTE_FILE" ]; then
    rm -f "$REMOTE_FILE"
    echo "   ✅ Removed: $REMOTE_FILE"
else
    echo "   ⚠️  Not found: $REMOTE_FILE"
fi

# 3. Remove configuration files
echo "3. Removing configuration files..."
CONFIG_FOUND=0

# Find all PowerDNS config files in cluster directory
find /var/cpanel/cluster -name "powerdns" -type f 2>/dev/null | while read config_file; do
    rm -f "$config_file"
    echo "   ✅ Removed config: $config_file"
    CONFIG_FOUND=1
done

if [ $CONFIG_FOUND -eq 0 ]; then
    echo "   ⚠️  No PowerDNS config files found"
fi

# Also check for config files in common locations
for user_dir in /var/cpanel/cluster/*/config/powerdns; do
    if [ -f "$user_dir" ]; then
        rm -f "$user_dir"
        echo "   ✅ Removed config: $user_dir"
    fi
done

# 4. Remove log files
echo "4. Removing log files..."
LOG_FILES=(
    "/usr/local/cpanel/logs/dnsadmin_powerdns_log"
    "/usr/local/cpanel/logs/dnsadmin_powerdns_setup_log"
)

for log_file in "${LOG_FILES[@]}"; do
    if [ -f "$log_file" ]; then
        rm -f "$log_file"
        echo "   ✅ Removed log: $log_file"
    else
        echo "   ⚠️  Not found: $log_file"
    fi
done

# 5. Clear cPanel cache
echo "5. Clearing cPanel cache..."
CACHE_SCRIPT=""
if [ -f "/usr/local/cpanel/scripts/update_cpanel_cache" ]; then
    CACHE_SCRIPT="/usr/local/cpanel/scripts/update_cpanel_cache"
elif [ -f "/scripts/update_cpanel_cache" ]; then
    CACHE_SCRIPT="/scripts/update_cpanel_cache"
fi

if [ -n "$CACHE_SCRIPT" ]; then
    $CACHE_SCRIPT >/dev/null 2>&1 || true
    echo "   ✅ Cache cleared"
else
    echo "   ⚠️  Cache script not found (cache may clear automatically)"
    # Try to remove cache files manually
    if [ -d "/var/cpanel/cpanel_cache" ]; then
        find /var/cpanel/cpanel_cache -name "*powerdns*" -type f -delete 2>/dev/null || true
        find /var/cpanel/cpanel_cache -name "*PowerDNS*" -type f -delete 2>/dev/null || true
        echo "   ✅ Removed PowerDNS-related cache files"
    fi
fi

# 6. Verify removal
echo ""
echo "6. Verifying removal..."
REMAINING_FILES=0

if [ -f "$SETUP_FILE" ]; then
    echo "   ⚠️  Setup module still exists: $SETUP_FILE"
    REMAINING_FILES=1
fi

if [ -f "$REMOTE_FILE" ]; then
    echo "   ⚠️  Remote module still exists: $REMOTE_FILE"
    REMAINING_FILES=1
fi

if find /var/cpanel/cluster -name "powerdns" -type f 2>/dev/null | grep -q .; then
    echo "   ⚠️  Some config files still exist:"
    find /var/cpanel/cluster -name "powerdns" -type f 2>/dev/null | sed 's/^/      /'
    REMAINING_FILES=1
fi

if [ $REMAINING_FILES -eq 0 ]; then
    echo "   ✅ All files removed successfully"
fi

# 7. Optional: Restart cPanel service
echo ""
read -p "Do you want to restart cPanel service to ensure changes take effect? (yes/no): " RESTART
if [ "$RESTART" = "yes" ]; then
    echo "7. Restarting cPanel service..."
    if [ -f "/scripts/restartsrv_cpsrvd" ]; then
        /scripts/restartsrv_cpsrvd >/dev/null 2>&1 || true
        echo "   ✅ cPanel service restarted"
    else
        echo "   ⚠️  Restart script not found"
    fi
else
    echo "7. Skipping cPanel service restart"
    echo "   Note: You may need to restart cPanel manually for changes to take effect"
fi

echo ""
echo "=== Uninstallation Complete ==="
echo ""
echo "The PowerDNS plugin has been removed from your system."
echo ""
echo "Note: If you had any DNS zones configured to use PowerDNS, you may need to:"
echo "  1. Reconfigure DNS clustering with a different backend"
echo "  2. Migrate any zones to another DNS backend"
echo "  3. Check WHM >> Clusters >> DNS Cluster to verify removal"
echo ""

