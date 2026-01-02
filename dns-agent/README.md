# DNS Notify Agent for cPanel

This agent listens on port 53 (UDP/TCP) for DNS NOTIFY messages from external PowerDNS servers. When a NOTIFY is received, it automatically syncs the zone to cPanel using the `dnscluster synczonelocal` command.

## Overview

The DNS Notify Agent acts as a DNS slave that receives zone change notifications (NOTIFY messages) from external PowerDNS servers. When a zone is updated on PowerDNS, it sends a NOTIFY message to this agent, which then triggers a zone sync on the cPanel server.

## Architecture

```
External PowerDNS (Master)
    │
    │ NOTIFY (port 53)
    ▼
DNS Notify Agent (on cPanel server, specific IP)
    │
    │ Executes: dnscluster synczonelocal -F <zone>
    ▼
cPanel DNS System
```

## Features

- **DNS NOTIFY Support**: Listens for and processes DNS NOTIFY messages
- **UDP and TCP Support**: Handles both UDP and TCP DNS messages
- **Zone Filtering**: Optional zone allowlist for security
- **Automatic Zone Sync**: Automatically syncs zones when NOTIFY is received
- **Logging**: Comprehensive logging to `/usr/local/cpanel/logs/dns_notify_agent.log`
- **Systemd Integration**: Runs as a systemd service
- **Configuration File**: Easy configuration via `/etc/cpanel-dns-agent.conf`

## Requirements

- cPanel/WHM installed
- Perl with Net::DNS module
- Root access for installation
- A dedicated IP address for the agent (recommended)
- External PowerDNS configured to send NOTIFY messages

## Installation

The agent is installed automatically when you run the main `install.sh` script:

```bash
sudo bash install.sh
```

### Manual Installation

```bash
# Copy agent script
cp dns-agent/dns_notify_agent.pl /usr/local/cpanel/bin/dns-notify-agent.pl
chmod 755 /usr/local/cpanel/bin/dns-notify-agent.pl

# Copy systemd service
cp dns-agent/dns-notify-agent.service /etc/systemd/system/
chmod 644 /etc/systemd/system/dns-notify-agent.service

# Copy configuration example
cp dns-agent/cpanel-dns-agent.conf.example /etc/cpanel-dns-agent.conf
chmod 644 /etc/cpanel-dns-agent.conf

# Install Net::DNS if needed
cpan Net::DNS
```

## Configuration

Edit `/etc/cpanel-dns-agent.conf`:

```ini
# IP address to bind to (use specific IP, not 0.0.0.0 for production)
bind_ip = 192.168.1.100

# Port to listen on (default: 53)
port = 53

# Log file path
log_file = /usr/local/cpanel/logs/dns_notify_agent.log

# PID file path
pid_file = /var/run/dns_notify_agent.pid

# Allowed zones (optional)
# If not specified, all zones are allowed
# Supports wildcards (e.g., *.example.com)
allowed_zone = example.com
allowed_zone = test.com
allowed_zone = *.example.com
```

### Important Configuration Notes

1. **bind_ip**: Use a specific IP address, not `0.0.0.0`. You should have a dedicated IP for the agent that's different from your main PowerDNS IP.

2. **allowed_zone**: If you want to restrict which zones can trigger syncs, list them here. If omitted, all zones are allowed.

3. **port**: Default is 53. Make sure this port is not already in use by another DNS server.

## Starting the Service

```bash
# Reload systemd
systemctl daemon-reload

# Enable service to start on boot
systemctl enable dns-notify-agent

# Start the service
systemctl start dns-notify-agent

# Check status
systemctl status dns-notify-agent

# View logs
tail -f /usr/local/cpanel/logs/dns_notify_agent.log
```

## Manual Execution

You can also run the agent manually for testing:

```bash
# Run in foreground (for debugging)
/usr/local/cpanel/bin/dns-notify-agent.pl --config /etc/cpanel-dns-agent.conf

# Run as daemon
/usr/local/cpanel/bin/dns-notify-agent.pl --daemon --config /etc/cpanel-dns-agent.conf

# Run with debug logging
/usr/local/cpanel/bin/dns-notify-agent.pl --debug --config /etc/cpanel-dns-agent.conf
```

## PowerDNS Configuration

Configure your external PowerDNS server to send NOTIFY messages to the agent. In PowerDNS configuration (`pdns.conf`), ensure:

1. **NOTIFY is enabled** (default)
2. **Slave zones are configured** to send NOTIFY to the agent's IP

Example PowerDNS zone configuration:

```sql
-- In PowerDNS database, set up slave zones
INSERT INTO domains (name, type) VALUES ('example.com', 'SLAVE');
INSERT INTO supermasters (ip, nameserver, account) VALUES ('192.168.1.100', 'ns1.example.com', 'admin');
```

Or via PowerDNS API:

```bash
curl -X POST "http://pdns-server:8081/api/v1/servers/localhost/zones" \
  -H "X-API-Key: your-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "example.com",
    "kind": "Slave",
    "masters": ["192.168.1.100:53"]
  }'
```

## How It Works

1. **External PowerDNS** updates a zone and sends a DNS NOTIFY message to the agent's IP:port
2. **DNS Notify Agent** receives the NOTIFY message on port 53
3. **Agent extracts** the zone name from the NOTIFY message
4. **Agent executes**: `/usr/local/cpanel/scripts/dnscluster synczonelocal -F <zone>`
5. **cPanel syncs** the zone from the external PowerDNS to local cPanel DNS

## Logging

All operations are logged to `/usr/local/cpanel/logs/dns_notify_agent.log`:

```
[2024-12-31 12:00:00] DNS Notify Agent starting (version 1.0)
[2024-12-31 12:00:00] Binding to 192.168.1.100:53
[2024-12-31 12:00:01] Received DNS NOTIFY from 192.168.1.50 (UDP)
[2024-12-31 12:00:01] NOTIFY for zone: example.com
[2024-12-31 12:00:01] Syncing zone: example.com
[2024-12-31 12:00:02] Successfully synced zone: example.com
```

## Troubleshooting

### Agent Not Starting

1. Check if port 53 is already in use:
   ```bash
   netstat -tulpn | grep :53
   ```

2. Check if Net::DNS is installed:
   ```bash
   /usr/local/cpanel/3rdparty/bin/perl -MNet::DNS -e "print 'OK\n'"
   ```

3. Check systemd logs:
   ```bash
   journalctl -u dns-notify-agent -n 50
   ```

### NOTIFY Messages Not Received

1. Verify agent is listening:
   ```bash
   netstat -tulpn | grep dns-notify-agent
   ```

2. Check firewall rules (allow UDP/TCP port 53 from PowerDNS server)

3. Test NOTIFY manually:
   ```bash
   dig @192.168.1.100 example.com SOA +notcp
   ```

4. Enable debug mode and check logs

### Zone Sync Fails

1. Check if zone exists in cPanel:
   ```bash
   /usr/local/cpanel/scripts/dnscluster synczonelocal -F example.com
   ```

2. Verify DNS clustering is enabled:
   ```bash
   test -f /var/cpanel/useclusteringdns && echo "Enabled" || echo "Disabled"
   ```

3. Check cPanel logs:
   ```bash
   tail -f /usr/local/cpanel/logs/dnsadmin_log
   ```

### Permission Issues

The agent must run as root to:
- Bind to port 53
- Execute `/usr/local/cpanel/scripts/dnscluster`
- Write to log and PID files

## Security Considerations

1. **Use a dedicated IP**: Don't bind to `0.0.0.0` in production. Use a specific IP address.

2. **Zone allowlist**: Configure `allowed_zone` to restrict which zones can trigger syncs.

3. **Firewall**: Only allow UDP/TCP port 53 from your PowerDNS server IPs.

4. **Network isolation**: Consider running the agent on a private network interface.

## Uninstallation

```bash
# Stop and disable service
systemctl stop dns-notify-agent
systemctl disable dns-notify-agent

# Remove files
rm /usr/local/cpanel/bin/dns-notify-agent.pl
rm /etc/systemd/system/dns-notify-agent.service
rm /etc/cpanel-dns-agent.conf
rm /var/run/dns_notify_agent.pid

# Reload systemd
systemctl daemon-reload
```

## Command Line Options

```
--config FILE      Configuration file (default: /etc/cpanel-dns-agent.conf)
--log FILE         Log file (default: /usr/local/cpanel/logs/dns_notify_agent.log)
--pid FILE         PID file (default: /var/run/dns_notify_agent.pid)
--bind-ip IP       IP address to bind to (default: 0.0.0.0)
--port PORT        Port to listen on (default: 53)
--daemon           Run as daemon
--debug            Enable debug logging
--help             Show help message
```

## Version

Current version: 1.0

## License

This code is subject to the cPanel license. Unauthorized copying is prohibited.


