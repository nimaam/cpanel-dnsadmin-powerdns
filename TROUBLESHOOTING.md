# PowerDNS cPanel Plugin Troubleshooting Guide

## Quick Diagnostic Steps

### Step 1: Run Diagnostic Scripts

```bash
cd ~/cpanel-dnsadmin-powerdns

# Test API connectivity
./test_connection.sh http://ns0.ultaservers.com:8081/api/v1 YOUR_API_KEY

# Test setup method directly
chmod +x debug_setup_direct.sh
./debug_setup_direct.sh

# Check for errors
./check_error.sh
```

### Step 2: Verify Installation

```bash
# Check if files are installed
ls -lh /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm
ls -lh /usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm

# Verify permissions
chmod 644 /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm
chmod 644 /usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm
```

### Step 3: Clear Cache and Restart

```bash
/usr/local/cpanel/scripts/update_cpanel_cache
/scripts/restartsrv_cpsrvd
```

### Step 4: Check Error Logs in Real-Time

```bash
# Terminal 1: Watch logs
tail -f /usr/local/cpanel/logs/error_log | grep -i -E "powerdns|dnsadmin|setup|apikey|clustering"

# Terminal 2: Try adding the server in WHM
# Then check Terminal 1 for errors
```

## Common Issues and Solutions

### Issue 1: "PowerDNS API Token" field not appearing

**Symptoms:**
- Only "PowerDNS API URL" field is visible
- "PowerDNS API Token" field is missing

**Solution:**
1. Verify the module is installed correctly:
   ```bash
   cat /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm | grep -A 5 '"apikey"'
   ```
   Should show the apikey field definition.

2. Clear browser cache and try again

3. Check if other backend modules show their fields correctly (for comparison)

### Issue 2: "Failed to set up DNS cluster for module 'PowerDNS'"

**Symptoms:**
- Generic error message with no details

**Solution:**
1. Check error logs:
   ```bash
   tail -50 /usr/local/cpanel/logs/error_log | grep -i powerdns
   ```

2. Run the direct setup test:
   ```bash
   ./debug_setup_direct.sh
   ```

3. Check if ACL is enabled:
   - Go to: `WHM >> Server Configuration >> Tweak Settings`
   - Ensure you have clustering ACL enabled

### Issue 3: "User does not have the clustering ACL enabled"

**Solution:**
- This means the user doesn't have permission
- Either use root user or enable clustering ACL for your user
- Go to: `WHM >> Server Configuration >> Tweak Settings`

### Issue 4: "Failed to connect to PowerDNS API"

**Symptoms:**
- Connection test fails during setup

**Solution:**
1. Test connectivity manually:
   ```bash
   ./test_connection.sh http://ns0.ultaservers.com:8081/api/v1 YOUR_API_KEY
   ```

2. Check firewall rules

3. Verify PowerDNS API is accessible from cPanel server

### Issue 5: Module not appearing in backend dropdown

**Solution:**
1. Reinstall:
   ```bash
   cd ~/cpanel-dnsadmin-powerdns
   ./install.sh
   ```

2. Clear cache:
   ```bash
   /usr/local/cpanel/scripts/update_cpanel_cache
   /scripts/restartsrv_cpsrvd
   ```

3. Verify dnsadmin is NOT dormant:
   - `WHM >> Server Configuration >> Tweak Settings`
   - Uncheck "dnsadmin" in Dormant services

## Getting Detailed Error Information

### Method 1: Check Error Logs

```bash
# Recent PowerDNS errors
grep -i powerdns /usr/local/cpanel/logs/error_log | tail -20

# All dnsadmin errors
grep -i dnsadmin /usr/local/cpanel/logs/error_log | tail -20
```

### Method 2: Enable Debug Mode

When adding the PowerDNS server, enable "Debug Mode" in the configuration form. This will log detailed API requests/responses to:
- `/usr/local/cpanel/logs/error_log`
- `/usr/local/cpanel/logs/dnsadmin_powerdns_log`

### Method 3: Test Setup Method Directly

```bash
./debug_setup_direct.sh
```

This will show:
- If the module loads correctly
- What fields are defined
- If setup method works with test data
- If config file is created

## What Information to Provide When Asking for Help

When reporting issues, please provide:

1. **Exact error message** from cPanel (copy/paste the full message)

2. **Screenshot or description** of the configuration form:
   - Which fields are visible?
   - Is "PowerDNS API Token" field showing?

3. **Output from diagnostic scripts:**
   ```bash
   ./test_connection.sh http://ns0.ultaservers.com:8081/api/v1 YOUR_API_KEY
   ./debug_setup_direct.sh
   ./check_error.sh
   ```

4. **Error log entries:**
   ```bash
   tail -50 /usr/local/cpanel/logs/error_log | grep -i powerdns
   ```

5. **cPanel version:**
   ```bash
   /usr/local/cpanel/bin/whmapi1 version
   ```

6. **Module file checksums:**
   ```bash
   md5sum /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm
   md5sum /usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm
   ```

## Verification Checklist

Before reporting issues, verify:

- [ ] Files are installed in correct locations
- [ ] File permissions are 644
- [ ] dnsadmin is NOT in dormant services
- [ ] API connectivity test passes
- [ ] Cache has been cleared
- [ ] cPanel service has been restarted
- [ ] Browser cache has been cleared
- [ ] User has clustering ACL enabled (if not root)





