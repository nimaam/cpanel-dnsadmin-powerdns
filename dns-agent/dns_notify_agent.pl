#!/usr/local/cpanel/3rdparty/bin/perl

# cpanel - dns_notify_agent.pl                      Copyright 2024
#                                                           All rights reserved.
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use IO::Socket::INET;
use IO::Select;
use Net::DNS;
use Cpanel::Logger;
use Getopt::Long;
use POSIX qw(setsid);
use File::Basename;

## no critic (RequireUseWarnings) -- requires auditing for potential warnings
our $VERSION = '1.0';

# Default configuration
my $DEFAULT_CONFIG_FILE = '/etc/cpanel-dns-agent.conf';
my $DEFAULT_LOG_FILE    = '/usr/local/cpanel/logs/dns_notify_agent.log';
my $DEFAULT_PID_FILE    = '/var/run/dns_notify_agent.pid';
my $DEFAULT_BIND_IP     = '0.0.0.0';
my $DEFAULT_PORT        = 53;

# Global variables
my $config_file = $DEFAULT_CONFIG_FILE;
my $log_file    = $DEFAULT_LOG_FILE;
my $pid_file    = $DEFAULT_PID_FILE;
my $bind_ip     = $DEFAULT_BIND_IP;
my $port        = $DEFAULT_PORT;
my $daemonize   = 0;
my $debug       = 0;
my $logger;
my %config;

# Parse command line options
GetOptions(
    'config=s'  => \$config_file,
    'log=s'     => \$log_file,
    'pid=s'     => \$pid_file,
    'bind-ip=s' => \$bind_ip,
    'port=i'    => \$port,
    'daemon'    => \$daemonize,
    'debug'     => \$debug,
    'help'      => sub { show_usage(); exit 0; },
) or die "Error in command line arguments\n";

show_usage() if @ARGV && $ARGV[0] eq 'help';

# Load configuration
load_config();

# Initialize logger
$logger = Cpanel::Logger->new( { 'alternate_logfile' => $log_file } );

# Daemonize if requested
if ($daemonize) {
    daemonize();
}

# Write PID file
write_pid_file();

# Setup signal handlers
$SIG{TERM} = \&cleanup;
$SIG{INT}  = \&cleanup;
$SIG{HUP}  = \&reload_config;

# Log startup
$logger->info("DNS Notify Agent starting (version $VERSION)");
$logger->info("Binding to $bind_ip:$port");
$logger->info("Log file: $log_file");
$logger->info("PID file: $pid_file");

# Create UDP socket
my $udp_socket = IO::Socket::INET->new(
    LocalAddr => $bind_ip,
    LocalPort => $port,
    Proto     => 'udp',
    ReuseAddr => 1,
    ReusePort => 1,
) or die "Cannot create UDP socket on $bind_ip:$port: $!\n";

# Create TCP socket
my $tcp_socket = IO::Socket::INET->new(
    LocalAddr => $bind_ip,
    LocalPort => $port,
    Proto     => 'tcp',
    ReuseAddr => 1,
    Listen    => 10,
) or die "Cannot create TCP socket on $bind_ip:$port: $!\n";

$logger->info("Sockets created successfully, listening for DNS NOTIFY messages...");

# Create IO::Select object
my $select = IO::Select->new();
$select->add($udp_socket);
$select->add($tcp_socket);

# Main event loop
main_loop();

sub main_loop {
    while (1) {
        my @ready = $select->can_read(1);

        foreach my $socket (@ready) {
            if ( $socket == $udp_socket ) {
                handle_udp_request($socket);
            }
            elsif ( $socket == $tcp_socket ) {
                handle_tcp_request($socket);
            }
        }
    }
}

sub handle_udp_request {
    my ($socket) = @_;

    my $data;
    my $peer_addr = $socket->recv( $data, 512 );
    return unless $peer_addr;

    my $peer_ip = $socket->peerhost();
    $logger->info("Received UDP packet from $peer_ip") if $debug;

    process_dns_message( $data, $socket, $peer_ip, 'UDP' );
}

sub handle_tcp_request {
    my ($socket) = @_;

    my $client = $socket->accept();
    return unless $client;

    my $peer_ip = $client->peerhost();
    $logger->info("Accepted TCP connection from $peer_ip") if $debug;

    # Read length prefix (2 bytes)
    my $length_data;
    my $bytes_read = $client->recv( $length_data, 2 );
    return unless $bytes_read == 2;

    my $length = unpack( 'n', $length_data );
    return if $length > 512 || $length < 12;

    # Read DNS message
    my $data;
    $bytes_read = $client->recv( $data, $length );
    return unless $bytes_read == $length;

    process_dns_message( $data, $client, $peer_ip, 'TCP' );
    $client->close();
}

sub process_dns_message {
    my ( $data, $socket, $peer_ip, $proto ) = @_;

    eval {
        my $packet = Net::DNS::Packet->new( \$data );
        return unless $packet;

        my $header = $packet->header;
        return unless $header;

        # Check if this is a NOTIFY message
        # NOTIFY has opcode = 4 (NOTIFY)
        my $opcode = $header->opcode;
        my $qr     = $header->qr;    # Query/Response flag

        # NOTIFY messages are queries (QR=0) with opcode=4
        if ( $opcode == 4 && !$qr ) {
            $logger->info("Received DNS NOTIFY from $peer_ip ($proto)");

            # Extract zone name from question section
            my @questions = $packet->question;
            if (@questions) {
                my $question = $questions[0];
                my $zone     = $question->qname;

                # Remove trailing dot if present
                $zone =~ s/\.$//;

                $logger->info("NOTIFY for zone: $zone");

                # Check if zone is in allowed list (if configured)
                if ( zone_allowed($zone) ) {
                    sync_zone($zone);
                }
                else {
                    $logger->info("Zone $zone not in allowed list, ignoring");
                }

                # Send NOTIFY response
                send_notify_response( $socket, $packet, $proto );
            }
            else {
                $logger->warning("NOTIFY message from $peer_ip has no question section");
            }
        }
        else {
            $logger->info("Received non-NOTIFY DNS message from $peer_ip ($proto), ignoring") if $debug;
        }
    };

    if ($@) {
        $logger->error("Error processing DNS message from $peer_ip: $@");
    }
}

sub send_notify_response {
    my ( $socket, $request_packet, $proto ) = @_;

    my @questions = $request_packet->question;
    return unless @questions;

    my $zone_name = $questions[0]->qname;

    eval {
        my $response = Net::DNS::Packet->new( $zone_name, 'SOA', 'IN' );
        $response->header->qr(1);           # Response
        $response->header->aa(1);           # Authoritative
        $response->header->id( $request_packet->header->id );

        my $response_data = $response->data;

        if ( $proto eq 'TCP' ) {
            # TCP requires length prefix
            my $length = length($response_data);
            $socket->send( pack( 'n', $length ) );
            $socket->send($response_data);
        }
        else {
            # UDP
            $socket->send( $response_data, $socket->peerhost() );
        }

        $logger->info("Sent NOTIFY response ($proto)") if $debug;
    };

    if ($@) {
        $logger->error("Error sending NOTIFY response: $@");
    }
}

sub sync_zone {
    my ($zone) = @_;

    $logger->info("Syncing zone: $zone");

    # Build command
    my $cmd = "/usr/local/cpanel/scripts/dnscluster synczonelocal -F $zone";

    # Execute command
    my $output = `$cmd 2>&1`;
    my $exit_code = $? >> 8;

    if ( $exit_code == 0 ) {
        $logger->info("Successfully synced zone: $zone");
        $logger->info("Command output: $output") if $debug && $output;
    }
    else {
        $logger->error("Failed to sync zone: $zone (exit code: $exit_code)");
        $logger->error("Command output: $output") if $output;
    }
}

sub zone_allowed {
    my ($zone) = @_;

    # If no allowed_zones configured, allow all
    return 1 unless exists $config{'allowed_zones'} && ref $config{'allowed_zones'} eq 'ARRAY';

    foreach my $allowed ( @{ $config{'allowed_zones'} } ) {
        # Support wildcard matching
        if ( $allowed =~ /\*/ ) {
            my $pattern = $allowed;
            $pattern =~ s/\*/.*/g;
            return 1 if $zone =~ /^$pattern$/i;
        }
        else {
            return 1 if lc($zone) eq lc($allowed);
        }
    }

    return 0;
}

sub load_config {
    # Initialize allowed_zones array
    $config{'allowed_zones'} = [] unless exists $config{'allowed_zones'};

    if ( -f $config_file ) {
        open( my $fh, '<', $config_file ) or die "Cannot read config file $config_file: $!\n";
        while ( my $line = <$fh> ) {
            chomp $line;
            $line =~ s/#.*$//;    # Remove comments
            $line =~ s/^\s+|\s+$//g;    # Trim whitespace
            next if $line eq '';

            if ( $line =~ /^(\w+)\s*=\s*(.+)$/ ) {
                my $key   = $1;
                my $value = $2;
                $value =~ s/^["']|["']$//g;    # Remove quotes

                if ( $key eq 'bind_ip' ) {
                    $bind_ip = $value;
                }
                elsif ( $key eq 'port' ) {
                    $port = $value;
                }
                elsif ( $key eq 'log_file' ) {
                    $log_file = $value;
                }
                elsif ( $key eq 'pid_file' ) {
                    $pid_file = $value;
                }
                elsif ( $key eq 'allowed_zone' || $key eq 'allowed_zones' ) {
                    $config{'allowed_zones'} = [] unless ref $config{'allowed_zones'} eq 'ARRAY';
                    push @{ $config{'allowed_zones'} }, split( /,/, $value );
                }
            }
        }
        close($fh);
    }
}

sub reload_config {
    $logger->info("Reloading configuration...");
    load_config();
    $logger->info("Configuration reloaded");
}

sub daemonize {
    my $pid = fork();
    die "Cannot fork: $!\n" unless defined $pid;

    exit 0 if $pid;    # Parent exits

    # Child continues
    setsid() or die "Cannot create new session: $!\n";

    # Change to root directory
    chdir '/' or die "Cannot change to root directory: $!\n";

    # Close file descriptors
    open( STDIN,  '<', '/dev/null' ) or die "Cannot read /dev/null: $!\n";
    open( STDOUT, '>', '/dev/null' ) or die "Cannot write /dev/null: $!\n";
    open( STDERR, '>', '/dev/null' ) or die "Cannot write /dev/null: $!\n";
}

sub write_pid_file {
    open( my $fh, '>', $pid_file ) or die "Cannot write PID file $pid_file: $!\n";
    print $fh $$;
    close($fh);
}

sub cleanup {
    $logger->info("Shutting down DNS Notify Agent...");
    unlink $pid_file if -f $pid_file;
    exit 0;
}

sub show_usage {
    print <<"EOM";
DNS Notify Agent for cPanel - Version $VERSION

Usage: $0 [OPTIONS]

Options:
    --config FILE      Configuration file (default: $DEFAULT_CONFIG_FILE)
    --log FILE         Log file (default: $DEFAULT_LOG_FILE)
    --pid FILE         PID file (default: $DEFAULT_PID_FILE)
    --bind-ip IP       IP address to bind to (default: $DEFAULT_BIND_IP)
    --port PORT        Port to listen on (default: $DEFAULT_PORT)
    --daemon           Run as daemon
    --debug            Enable debug logging
    --help             Show this help message

Description:
    This agent listens on port 53 (UDP/TCP) for DNS NOTIFY messages from
    external PowerDNS servers. When a NOTIFY is received, it extracts the
    zone name and executes:
    
    /usr/local/cpanel/scripts/dnscluster synczonelocal -F <zone>
    
    This allows cPanel to automatically sync zones when changes occur on
    the external PowerDNS server.

Configuration File:
    The configuration file supports the following options:
    
    bind_ip = 192.168.1.100
    port = 53
    log_file = /usr/local/cpanel/logs/dns_notify_agent.log
    pid_file = /var/run/dns_notify_agent.pid
    allowed_zone = example.com
    allowed_zone = *.example.com
    
    If no allowed_zone entries are specified, all zones are allowed.

Examples:
    # Run in foreground with default settings
    $0
    
    # Run as daemon on specific IP
    $0 --daemon --bind-ip 192.168.1.100 --port 53
    
    # Run with custom config file
    $0 --config /etc/custom-dns-agent.conf --daemon

EOM
}

