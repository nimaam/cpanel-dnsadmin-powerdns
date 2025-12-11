# cPanel dnsadmin PowerDNS Plugin

A custom dnsadmin plugin for cPanel & WHM that integrates with PowerDNS v4 API.

## Overview

This plugin allows cPanel to manage DNS zones and records through PowerDNS v4 API, enabling you to use PowerDNS as a backend for cPanel's DNS management system.

## Requirements

- cPanel & WHM server
- PowerDNS v4 server with API enabled
- Perl modules:
  - `JSON`
  - `LWP::UserAgent`
  - `HTTP::Request`
  - Standard cPanel Perl modules

## Installation

### 1. Copy Module Files

Copy the module files to their respective directories on your cPanel server:

```bash
# Copy Setup module
cp lib/Cpanel/NameServer/Setup/Remote/PowerDNS.pm /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm

# Copy Remote module
cp lib/Cpanel/NameServer/Remote/PowerDNS.pm /usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm

# Set proper permissions
chmod 644 /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm
chmod 644 /usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm
```

### 2. Disable Dormant Services

**Important:** You must disable the dnsadmin checkbox for the "Dormant services" setting in WHM:

1. Navigate to: `WHM >> Home >> Server Configuration >> Tweak Settings`
2. Find the "Dormant services" section
3. Uncheck the "dnsadmin" checkbox
4. Click "Save"

### 3. Configure PowerDNS Node

1. Navigate to: `WHM >> Home >> Clusters >> DNS Cluster`
2. Click "Add a DNS Server"
3. Select "PowerDNS" from the "Backend Type" dropdown
4. Click "Configure"
5. Fill in the configuration form:
   - **PowerDNS API URL**: The full URL to your PowerDNS API (e.g., `https://powerdns.example.com:8081/api/v1` or `https://powerdns.example.com/api/v1`)
     - Standard ports (80 for HTTP, 443 for HTTPS) are automatically excluded from the URL
     - The URL should include the full path to the API (typically `/api/v1`)
   - **PowerDNS API Token**: Your PowerDNS API token/key
   - **Enable Debug Mode**: Enable for troubleshooting
6. Click "Submit"

## Configuration

### Node Configuration File

After configuration, a node configuration file is created at:
```
/var/cpanel/cluster/{username}/config/powerdns
```

The file contains:
```
#version 2.0
user={username}
api_url={full_api_url}
pass={api_token}
module=PowerDNS
debug={on|off}
```

Example:
```
#version 2.0
user=root
api_url=https://powerdns.example.com:8081/api/v1
pass=your-api-token-here
module=PowerDNS
debug=off
```

### PowerDNS API Requirements

Your PowerDNS server must have:
- API enabled and accessible
- Valid API key configured
- Network access from cPanel server to PowerDNS server
- Appropriate firewall rules

## Features

The plugin implements all required dnsadmin command methods:

- **Zone Management**:
  - `addzoneconf()` - Add a new zone
  - `removezone()` - Remove a zone
  - `removezones()` - Remove multiple zones
  - `quickzoneadd()` - Quickly add a zone
  - `zoneexists()` - Check if a zone exists

- **Zone Retrieval**:
  - `getzone()` - Get a single zone
  - `getzones()` - Get multiple zones
  - `getzonelist()` - List all zones
  - `getallzones()` - Get all zones

- **Zone Operations**:
  - `savezone()` - Save/update a zone
  - `synczones()` - Synchronize zones

- **System Information**:
  - `getips()` - Get nameserver IP addresses
  - `getpath()` - Get node path
  - `version()` - Get module version

- **DNSSEC**:
  - `synckeys()` - Synchronize DNSSEC keys
  - `revokekeys()` - Revoke DNSSEC keys

## Testing

After installation, test the integration:

1. Navigate to: `WHM >> Home >> Clusters >> DNS Cluster`
2. Verify "PowerDNS" appears in the Backend Type menu
3. Add a test zone through cPanel's DNS management interface
4. Verify the zone appears in PowerDNS
5. Check logs if debug mode is enabled

## Troubleshooting

### Module Not Appearing in Backend Type Menu

**Important:** The syntax check error you see with system Perl is **normal and expected**. cPanel uses its own Perl interpreter with different module paths. The module will work when loaded by cPanel's Perl.

**Troubleshooting Steps:**

1. **Verify file locations and permissions:**
   ```bash
   ls -lh /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm
   ls -lh /usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm
   ```
   Both files should exist and have permissions `644`.

2. **Fix permissions if needed:**
   ```bash
   chmod 644 /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm
   chmod 644 /usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm
   ```

3. **Clear cPanel cache:**
   ```bash
   /usr/local/cpanel/scripts/update_cpanel_cache
   ```

4. **Restart cPanel service:**
   ```bash
   /scripts/restartsrv_cpsrvd
   ```

5. **Verify dnsadmin is NOT dormant:**
   - Go to: `WHM >> Server Configuration >> Tweak Settings`
   - Find "Dormant services" section
   - Ensure "dnsadmin" is **unchecked**
   - Click "Save"

6. **Check cPanel error logs:**
   ```bash
   tail -f /usr/local/cpanel/logs/error_log
   ```
   Then try accessing: `WHM >> Clusters >> DNS Cluster >> Add a DNS Server`
   Look for any PowerDNS-related errors.

7. **Test module loading with cPanel Perl:**
   ```bash
   /usr/local/cpanel/3rdparty/bin/perl -I/usr/local/cpanel/Cpanel -I/usr/local/cpanel -e 'use Cpanel::NameServer::Setup::Remote::PowerDNS; print "OK\n";'
   ```
   If this works, the module is loadable by cPanel.

8. **Check for other backend modules (for comparison):**
   ```bash
   ls -la /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/
   ```
   Compare permissions and structure with other working modules.

9. **Clear browser cache** and try accessing the DNS Cluster page again.

10. **Run the verification script:**
    ```bash
    chmod +x verify_installation.sh
    ./verify_installation.sh
    ```

### API Connection Issues

- Verify PowerDNS API is accessible from cPanel server
- Test API connectivity: `curl -H "X-API-Key: YOUR_TOKEN" https://powerdns-host:8081/api/v1/servers/localhost`
- Check firewall rules
- Verify API token is correct
- Verify the API URL is correct and includes the full path (e.g., `/api/v1`)
- Enable debug mode to see detailed API requests/responses

### Zone Format Issues

The plugin converts between cPanel zone format and PowerDNS API format. If you encounter issues:
- Check PowerDNS API documentation for zone format requirements
- Review the `_cpanel_to_powerdns_zone()` and `_powerdns_to_cpanel_zone()` methods
- Enable debug mode to see zone conversion details

### Logs

- cPanel error log: `/usr/local/cpanel/logs/error_log`
- dnsadmin logs: `/var/log/dnsadmin_log`
- Debug output (when enabled): Check logger output

## API Endpoints Used

The plugin uses the following PowerDNS v4 API endpoints (server name is always `localhost`):

- `GET {api_url}/servers/localhost/zones` - List zones
- `GET {api_url}/servers/localhost/zones/{zone}` - Get zone
- `POST {api_url}/servers/localhost/zones` - Create zone
- `PATCH {api_url}/servers/localhost/zones/{zone}` - Update zone
- `DELETE {api_url}/servers/localhost/zones/{zone}` - Delete zone
- `GET {api_url}/servers/localhost` - Get server info
- `GET {api_url}/servers/localhost/statistics` - Get statistics

Where `{api_url}` is the base URL you configured (e.g., `https://powerdns.example.com:8081/api/v1`).

## Development

### Module Structure

- **Setup Module**: `/usr/local/cpanel/Cpanel/NameServer/Setup/Remote/PowerDNS.pm`
  - Handles configuration form and node setup
  - Creates node configuration files

- **Remote Module**: `/usr/local/cpanel/Cpanel/NameServer/Remote/PowerDNS.pm`
  - Handles all DNS operations
  - Communicates with PowerDNS API
  - Implements all required command methods

### Customization

You may need to customize:
- Zone format conversion methods (`_cpanel_to_powerdns_zone`, `_powerdns_to_cpanel_zone`)
- API endpoint paths
- Error handling
- Authentication method

## References

- [cPanel dnsadmin Plugin Documentation](https://api.docs.cpanel.net/guides/guide-to-custom-dnsadmin-plugins/)
- [PowerDNS API Documentation](https://doc.powerdns.com/authoritative/http-api/)

## License

This plugin is provided as-is for integration with cPanel & WHM and PowerDNS.

## Support

For issues related to:
- **cPanel integration**: Check cPanel documentation and error logs
- **PowerDNS API**: Refer to PowerDNS documentation
- **This plugin**: Review code and adjust as needed for your environment

