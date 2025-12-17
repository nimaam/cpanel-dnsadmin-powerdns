# PowerDNS URL Configuration and Logging Guide

## PowerDNS API URL Format

### Both formats work, but we recommend the explicit format:

**Option 1 (Recommended - Explicit):**
```
http://ns0.ultaservers.net:8081/api/v1
```

**Option 2 (Auto-appends /api/v1):**
```
http://ns0.ultaservers.net:8081
```
This will automatically become: `http://ns0.ultaservers.net:8081/api/v1`

### How it works:

The plugin's `_parse_api_url` method automatically:
- If you provide a path (like `/api/v1`), it uses that path
- If you don't provide a path, it defaults to `/api/v1`

**Recommendation:** Use the explicit format (`http://ns0.ultaservers.net:8081/api/v1`) to ensure clarity and avoid any potential issues.

### Examples:

✅ **Correct:**
- `http://ns0.ultaservers.net:8081/api/v1`
- `https://powerdns.example.com:8081/api/v1`
- `http://powerdns.example.com/api/v1` (port 80, auto-appends /api/v1)
- `https://powerdns.example.com/api/v1` (port 443, auto-appends /api/v1)

✅ **Also works (auto-appends /api/v1):**
- `http://ns0.ultaservers.net:8081`
- `https://powerdns.example.com:8081`

## Testing the API URL

Before configuring in cPanel, test if your PowerDNS API is accessible:

```bash
# Test with your API token
curl -H "X-API-Key: YOUR_API_TOKEN" http://ns0.ultaservers.net:8081/api/v1/servers/localhost
```

If successful, you should get JSON response with server information.

## Log Files

### 1. cPanel Error Log
**Location:** `/usr/local/cpanel/logs/error_log`

**View in real-time:**
```bash
tail -f /usr/local/cpanel/logs/error_log
```

**Search for PowerDNS errors:**
```bash
grep -i powerdns /usr/local/cpanel/logs/error_log
```

### 2. dnsadmin Log
**Location:** `/var/log/dnsadmin_log`

**View in real-time:**
```bash
tail -f /var/log/dnsadmin_log
```

**View recent entries:**
```bash
tail -50 /var/log/dnsadmin_log
```

### 3. Debug Mode Logs
When **Debug Mode** is enabled in the PowerDNS node configuration, detailed API requests and responses are logged.

**To enable Debug Mode:**
1. Go to: `WHM >> Clusters >> DNS Cluster`
2. Edit your PowerDNS node
3. Enable "Debug Mode"
4. Save

**Debug logs include:**
- All PowerDNS API requests (method, URL, data)
- All PowerDNS API responses (status code, content)
- Zone conversion details

**Where debug logs appear:**
- Debug output goes to the cPanel logger system
- Check `/usr/local/cpanel/logs/error_log` for debug messages
- Look for lines containing "PowerDNS API Request:" and "PowerDNS API Response:"

**Example debug log entries:**
```
PowerDNS API Request: GET http://ns0.ultaservers.net:8081/api/v1/servers/localhost/zones
Request Data: 
PowerDNS API Response Status: 200
PowerDNS API Response: [{"name":"example.com",...}]
```

### 4. PowerDNS Server Logs
If you need to check logs on the PowerDNS server itself:

**PowerDNS Authoritative Server logs:**
- Location varies by installation
- Common locations:
  - `/var/log/powerdns.log`
  - `/var/log/pdns.log`
  - Systemd journal: `journalctl -u pdns`

**View PowerDNS logs:**
```bash
# If using systemd
journalctl -u pdns -f

# If using syslog
tail -f /var/log/powerdns.log
```

## Troubleshooting with Logs

### If PowerDNS doesn't appear in backend dropdown:
```bash
grep -i "powerdns\|nameserver.*setup" /usr/local/cpanel/logs/error_log | tail -20
```

### If API connection fails:
```bash
# Check for API errors
grep -i "powerdns.*api" /usr/local/cpanel/logs/error_log | tail -20

# Check dnsadmin logs
tail -50 /var/log/dnsadmin_log
```

### If zones aren't syncing:
```bash
# Enable debug mode first, then:
tail -f /usr/local/cpanel/logs/error_log | grep -i powerdns
```

## Quick Log Commands Reference

```bash
# View all PowerDNS-related errors
grep -i powerdns /usr/local/cpanel/logs/error_log

# Monitor PowerDNS activity in real-time
tail -f /usr/local/cpanel/logs/error_log | grep -i powerdns

# Check recent dnsadmin activity
tail -100 /var/log/dnsadmin_log

# View last 50 lines of error log
tail -50 /usr/local/cpanel/logs/error_log

# Search for specific zone operations
grep "example.com" /usr/local/cpanel/logs/error_log
```

## Configuration File Location

After configuration, the node config file is created at:
```
/var/cpanel/cluster/{username}/config/powerdns
```

**View configuration:**
```bash
cat /var/cpanel/cluster/root/config/powerdns
```

**Example content:**
```
#version 2.0
user=root
api_url=http://ns0.ultaservers.net:8081/api/v1
pass=your-api-token-here
module=PowerDNS
debug=off
```





