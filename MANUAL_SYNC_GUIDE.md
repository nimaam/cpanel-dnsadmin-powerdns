# Manual DNS Synchronization Guide

This guide explains how to manually trigger DNS cluster synchronization for the PowerDNS backend.

## Quick Start

### Method 1: Using WHMAPI1 (Recommended)

```bash
# List available DNS cluster nodes
/usr/local/cpanel/bin/whmapi1 list_dns_cluster_nodes

# Synchronize all zones to a specific PowerDNS node
/usr/local/cpanel/bin/whmapi1 dnscluster_sync_zones dnspeer=<your-powerdns-hostname>
```

**Example:**
```bash
/usr/local/cpanel/bin/whmapi1 dnscluster_sync_zones dnspeer=powerdns.example.com
```

### Method 2: From WHM Web Interface

1. Navigate to: **WHM >> Home >> Clusters >> DNS Cluster**
2. Find your PowerDNS server in the list
3. Click the **"Synchronize DNS Records"** button (or similar action)
4. Monitor the progress

## What Happens During Synchronization

With the updated implementation, `synczones()` now:

1. **Receives zone data** from cPanel dnsadmin in the format:
   ```
   cpdnszone-<encoded_zone_name>=<encoded_zone_data>&cpdnszone-<another_zone>=<data>&...
   ```

2. **Parses the data** to extract all zones and their zonefile contents

3. **For each zone:**
   - Checks if the zone exists in PowerDNS
   - Creates the zone if it doesn't exist (via `addzoneconf`)
   - Saves/updates the zone data (via `savezone`)

4. **Handles errors:**
   - Recoverable errors (timeouts, auth failures) are returned immediately for retry
   - Non-recoverable errors stop the sync process

## Monitoring Synchronization

### Enable Debug Mode

Edit the PowerDNS config file:
```bash
vi /var/cpanel/cluster/root/config/powerdns
```

Set:
```
debug=on
```

### Monitor Logs

**In one terminal, watch the PowerDNS plugin log:**
```bash
tail -f /usr/local/cpanel/logs/dnsadmin_powerdns_log
```

**In another terminal, watch the general dnsadmin log:**
```bash
tail -f /usr/local/cpanel/logs/dnsadmin_log
```

**In a third terminal, trigger the sync:**
```bash
/usr/local/cpanel/bin/whmapi1 dnscluster_sync_zones dnspeer=<your-powerdns-host>
```

### What to Look For

**Successful sync:**
- API requests to PowerDNS: `GET /servers/localhost/zones/<zone>`
- Zone creation: `POST /servers/localhost/zones` (if zone doesn't exist)
- Zone updates: `PATCH /servers/localhost/zones/<zone>` (for each zone)
- Success messages in logs

**Errors to watch for:**
- Connection timeouts
- Authentication failures (401/403)
- Invalid zone data
- PowerDNS API errors

## Testing the Implementation

### Run the Test Script

```bash
chmod +x manual_sync_test.sh
./manual_sync_test.sh
```

This script will:
- Show you how to use WHMAPI1
- List available DNS cluster nodes
- Explain the current implementation status
- Provide monitoring instructions

### Verify Zones in PowerDNS

After synchronization, verify zones exist in PowerDNS:

```bash
# Using curl (adjust URL and API key)
API_URL="http://your-powerdns:8081/api/v1"
API_KEY="your-api-key"

# List all zones
curl -H "X-API-Key: $API_KEY" \
     -H "Accept: application/json" \
     "$API_URL/servers/localhost/zones" | jq .

# Get a specific zone
curl -H "X-API-Key: $API_KEY" \
     -H "Accept: application/json" \
     "$API_URL/servers/localhost/zones/example.com." | jq .
```

## Implementation Details

### Comparison with SoftLayer/VPSNET

The PowerDNS `synczones()` implementation now matches the pattern used by SoftLayer and VPSNET:

| Feature | SoftLayer/VPSNET | PowerDNS (Updated) |
|---------|------------------|-------------------|
| Parse rawdata | ✅ | ✅ |
| Extract cpdnszone- entries | ✅ | ✅ |
| Check zone existence | ✅ | ✅ |
| Create missing zones | ✅ | ✅ |
| Save zone data | ✅ | ✅ |
| Handle recoverable errors | ✅ | ✅ |
| Extended timeout for bulk ops | ✅ | ✅ |

### Key Differences

- **SoftLayer/VPSNET**: Use their own domain ID caching (`DOMAIN_INFO` / `DOMAIN_IDS`)
- **PowerDNS**: Uses direct API calls to check zone existence (no caching needed)

## Troubleshooting

### Sync Returns Success But Zones Not Updated

1. **Check PowerDNS API connectivity:**
   ```bash
   curl -H "X-API-Key: YOUR_KEY" \
        "$API_URL/servers/localhost/zones"
   ```

2. **Enable debug mode** and check logs for API errors

3. **Verify zone data format** - check if zone data is being parsed correctly

### "Too many arguments" Error

This should be fixed with the `determine_error_type` override. If you still see it:
- Ensure you have the latest version of the module installed
- Restart cPanel: `/scripts/restartsrv_cpsrvd`

### Timeout Errors

- Increase timeout in config (if supported)
- Check network connectivity between cPanel and PowerDNS
- Verify PowerDNS API is responsive

## Manual Zone Sync (Individual Zones)

Individual zones are automatically synced when:
- A DNS record is added/modified/deleted in cPanel
- A zone is created in cPanel

This triggers `savezone()` which updates PowerDNS immediately.

To force a single zone sync:
1. Make a small change to the zone in cPanel (add/remove a record)
2. Save the changes
3. This will trigger `savezone()` automatically

## API Endpoints Used During Sync

During synchronization, the following PowerDNS API endpoints are called:

1. **Check zone exists:**
   ```
   GET /servers/localhost/zones/{zone}
   ```

2. **Create zone (if missing):**
   ```
   POST /servers/localhost/zones
   Body: {"name": "zone.com", "kind": "Native", "dnssec": 0, "nameservers": []}
   ```

3. **Update zone data:**
   ```
   PATCH /servers/localhost/zones/{zone}
   Body: {"rrsets": [...]}
   ```

## Next Steps

After implementing full synchronization:

1. **Test with a small number of zones first**
2. **Monitor logs during sync**
3. **Verify zones in PowerDNS after sync**
4. **Test error handling** (disconnect PowerDNS, invalid API key, etc.)
5. **Test recoverable errors** (timeouts) to ensure retry works

## Related Files

- `cPanel-Nameserver/Remote/PowerDNS.pm` - Main implementation
- `lib/Cpanel/NameServer/Remote/PowerDNS.pm` - Source version
- `manual_sync_test.sh` - Test script
- `cPanel-Nameserver/Remote/SoftLayer.pm` - Reference implementation (lines 556-589)
- `cPanel-Nameserver/Remote/VPSNET.pm` - Reference implementation (lines 346-378)

