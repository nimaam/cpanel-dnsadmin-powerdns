# External PDNS Module and DNS Notify Agent for cPanel

This package provides two components for integrating cPanel with external PowerDNS Authoritative Server (version 4.8+):

1. **dnsadmin Module**: Syncs zones from cPanel to external PowerDNS via HTTP API
2. **DNS Notify Agent**: Receives NOTIFY messages from PowerDNS and syncs zones back to cPanel

## Components

### 1. External PDNS dnsadmin Module

The dnsadmin module provides integration between cPanel's dnsadmin system and external PowerDNS via the PowerDNS HTTP API.

**Features:**
- **Full DNS Zone Management**: Create, update, delete, and retrieve DNS zones
- **Primary Zone Type**: Automatically sets zones as Primary type (required for external PowerDNS)
- **NS Record Rewriting**: Configurable nameserver record handling (force/ensure/default)
- **Comprehensive Logging**: All operations logged to `/usr/local/cpanel/logs/dnsadmin_externalpdns_log`
- **Error Handling**: Robust error handling with automatic retry queuing
- **All Record Types**: Supports SOA, A, AAAA, CNAME, MX, NS, TXT, SRV, PTR

### 2. DNS Notify Agent

The DNS Notify Agent listens on port 53 (UDP/TCP) for DNS NOTIFY messages from external PowerDNS servers. When a zone is updated on PowerDNS, it automatically syncs the zone back to cPanel.

**Features:**
- **DNS NOTIFY Support**: Listens for and processes DNS NOTIFY messages
- **UDP and TCP Support**: Handles both UDP and TCP DNS messages
- **Zone Filtering**: Optional zone allowlist for security
- **Automatic Zone Sync**: Automatically syncs zones when NOTIFY is received
- **Systemd Integration**: Runs as a systemd service
- **Comprehensive Logging**: All operations logged to `/usr/local/cpanel/logs/dns_notify_agent.log`

## Requirements

- cPanel/WHM installed
- External PowerDNS Authoritative Server 4.8+ with HTTP API enabled
- PowerDNS API key configured
- Network access from cPanel server to PowerDNS API

## Installation

### Quick Install

```bash
# Clone the repository
git clone git@github.com:nimaam/cpanel-dnsadmin-powerdns.git
cd cpanel-dnsadmin-powerdns

# Run installation script (as root)
sudo bash install.sh
```

This will install both:
- The dnsadmin module (for syncing cPanel → PowerDNS)
- The DNS Notify Agent (for syncing PowerDNS → cPanel)

### Manual Install

```bash
# Copy Setup module
cp cPanel-dnsadmin/Setup/Remote/ExternalPDNS.pm \
   /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/ExternalPDNS.pm
chmod 644 /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/ExternalPDNS.pm

# Copy Remote module
cp cPanel-dnsadmin/Remote/ExternalPDNS.pm \
   /usr/local/cpanel/Cpanel/NameServer/Remote/ExternalPDNS.pm
chmod 644 /usr/local/cpanel/Cpanel/NameServer/Remote/ExternalPDNS.pm
```

## Configuration

### PowerDNS API Setup

1. **Enable API in PowerDNS** (`pdns.conf`):
   ```
   webserver=yes
   webserver-address=0.0.0.0
   webserver-port=8081
   api=yes
   api-key=your-secret-api-key-here
   ```

2. **Restart PowerDNS**:
   ```bash
   systemctl restart pdns
   ```

### Adding Node in cPanel

1. Log in to **WHM**
2. Navigate to **DNS Clustering** → **Add Node**
3. Select **"External PDNS"** as the node type
4. Fill in the configuration:
   - **API URL**: `http://your-pdns-server:8081` (or `https://...`)
   - **API Key**: Your PowerDNS API key
   - **Server ID**: Usually `localhost` (or your server identifier)
   - **NS Config**: Choose handling mode:
     - `force`: Replace all NS records with PowerDNS nameservers
     - `ensure`: Add PowerDNS nameservers if not present
     - `default`: Don't modify NS records
   - **PowerDNS Nameservers**: Comma-separated list (e.g., `ns1.example.com,ns2.example.com`)
   - **Debug Mode**: Enable for detailed logging

## Configuration Options

| Option | Description | Required | Example |
|--------|-------------|----------|---------|
| `api_url` | PowerDNS API URL | Yes | `http://pdns.example.com:8081` |
| `apikey` | PowerDNS API key | Yes | `your-api-key-here` |
| `server_id` | PowerDNS server ID | No (default: `localhost`) | `localhost` |
| `ns_config` | NS record handling | Yes | `force`, `ensure`, or `default` |
| `powerdns_ns` | Nameservers list | Yes (if force/ensure) | `ns1.example.com,ns2.example.com` |
| `debug` | Debug logging | No | `0` or `1` |

## NS Record Handling

### Force Mode
Replaces all NS records in the zone with the configured PowerDNS nameservers.

**Use case**: When you want all zones to use your PowerDNS nameservers exclusively.

### Ensure Mode
Adds PowerDNS nameservers to the zone if they're not already present, but keeps existing NS records.

**Use case**: When you want to ensure your PowerDNS nameservers are included but preserve other NS records.

### Default Mode
Does not modify NS records at all.

**Use case**: When you want full control over NS records or they're managed elsewhere.

## Logging

All operations are logged to:
```
/usr/local/cpanel/logs/dnsadmin_externalpdns_log
```

The log includes:
- All API requests (method, URL, payload)
- All API responses (status, errors, data)
- Method calls with parameters
- NS rewriting decisions
- Zone operations (create, update, delete)

**Note**: Logging is always enabled, not just in debug mode, for troubleshooting purposes.

## Zone Type: Primary

This module **always** sets zones as `Primary` type when creating them. This is critical because:

- Primary zones are authoritative on the PowerDNS server
- Primary zones are automatically published to DNS slave nodes by the master PowerDNS server
- Other zone types (Native, Slave) won't work correctly for external PowerDNS integration

## API Endpoints Used

The module uses the following PowerDNS API endpoints:

- `GET /api/v1/servers/{server_id}/zones` - List all zones
- `GET /api/v1/servers/{server_id}/zones/{zone_fqdn}` - Get zone details
- `POST /api/v1/servers/{server_id}/zones` - Create zone
- `PUT /api/v1/servers/{server_id}/zones/{zone_fqdn}` - Update zone (replace all records)
- `DELETE /api/v1/servers/{server_id}/zones/{zone_fqdn}` - Delete zone

## Troubleshooting

### Module Not Appearing in WHM

1. Verify files are installed:
   ```bash
   ls -la /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/ExternalPDNS.pm
   ls -la /usr/local/cpanel/Cpanel/NameServer/Remote/ExternalPDNS.pm
   ```

2. Check file permissions (should be 644)

3. Restart cPanel services if needed

### API Connection Errors

1. Verify PowerDNS API is accessible:
   ```bash
   curl -H "X-API-Key: your-key" http://your-pdns-server:8081/api/v1/servers/localhost
   ```

2. Check firewall rules

3. Verify API key is correct

4. Check log file: `/usr/local/cpanel/logs/dnsadmin_externalpdns_log`

### Zone Creation Fails

1. Ensure zone name is valid
2. Check if zone already exists
3. Verify API key has proper permissions
4. Check PowerDNS logs

### NS Records Not Updating

1. Verify `powerdns_ns` is configured correctly
2. Check `ns_config` setting (force/ensure/default)
3. Review log file for errors

## Uninstallation

```bash
# Remove Setup module
rm /usr/local/cpanel/Cpanel/NameServer/Setup/Remote/ExternalPDNS.pm

# Remove Remote module
rm /usr/local/cpanel/Cpanel/NameServer/Remote/ExternalPDNS.pm

# Remove configuration files (if any)
rm -rf /var/cpanel/cluster/*/config/externalpdns
```

## Support

For issues or questions:
- Check the log file: `/usr/local/cpanel/logs/dnsadmin_externalpdns_log`
- Review PowerDNS API documentation: https://doc.powerdns.com/authoritative/http-api/
- Check cPanel dnsadmin documentation

## License

This code is subject to the cPanel license. Unauthorized copying is prohibited.

## Architecture

```
┌─────────────────┐         ┌──────────────────┐         ┌─────────────────┐
│   cPanel DNS    │────────▶│  External PDNS   │────────▶│  DNS Notify     │
│   (dnsadmin)    │  HTTP   │  (Master)        │  NOTIFY │  Agent          │
│                 │  API    │                  │  (53)   │  (cPanel)       │
└─────────────────┘         └──────────────────┘         └─────────────────┘
      │                                                          │
      │                                                          │
      └──────────────────────────────────────────────────────────┘
                    dnscluster synczonelocal
```

**Flow:**
1. cPanel changes a zone → dnsadmin module syncs to PowerDNS via HTTP API
2. PowerDNS updates zone → sends NOTIFY to DNS Notify Agent
3. DNS Notify Agent receives NOTIFY → executes `dnscluster synczonelocal -F <zone>`
4. Zone is synced back to cPanel

## DNS Notify Agent Setup

After installation, configure and start the DNS Notify Agent:

```bash
# Edit configuration
vi /etc/cpanel-dns-agent.conf

# Set bind_ip to your dedicated IP (not 0.0.0.0)
# bind_ip = 192.168.1.100

# Enable and start service
systemctl daemon-reload
systemctl enable dns-notify-agent
systemctl start dns-notify-agent

# Check status
systemctl status dns-notify-agent
tail -f /usr/local/cpanel/logs/dns_notify_agent.log
```

For detailed DNS Notify Agent documentation, see [dns-agent/README.md](dns-agent/README.md).

## Version

Current version: 1.0

