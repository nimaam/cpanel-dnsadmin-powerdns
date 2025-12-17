package Cpanel::NameServer::Utils::PowerDNS;

# cpanel - Cpanel/NameServer/Utils/PowerDNS.pm     Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

=encoding utf-8

=head1 NAME

Cpanel::NameServer::Utils::PowerDNS - Tools for interaction with PowerDNS

=head1 SYNOPSIS

    use Cpanel::NameServer::Utils::PowerDNS ();

    Cpanel::NameServer::Utils::PowerDNS::run_pdnssec( { 'args' => [ 'disable-dnssec', '--', $domain ] } );

    Cpanel::NameServer::Utils::PowerDNS::run_pdns_control( { 'args' => [ 'purge', '--', $domain ] } );

=cut

=head2 pdns_control()

Returns the path to the pdns_control binary

=cut

sub pdns_control { return '/usr/bin/pdns_control'; }

=head2 pdnsutil()

Returns the path to the pdnsutil binary

=cut

sub pdnsutil { return '/usr/bin/pdnsutil'; }

=head2 run_pdnssec()

Run the pdnssec binary with arguments and return the output

=cut

sub run_pdnsutil { return _run_util( pdnsutil(), @_ ); }

=head2 run_pdns_control()

Run the pdns_control binary with arguments and return the output

=cut

sub run_pdns_control { return _run_util( pdns_control(), @_ ); }

sub _run_util {
    my ( $utility, $opts_hr ) = @_;

    # We use the webserver api most of the time now so this should
    # be a rare operation.  Only load saferun::object when we need it.
    require Cpanel::SafeRun::Object;
    my $run = Cpanel::SafeRun::Object->new(
        'program' => $utility,
        'args'    => $opts_hr->{'args'},
    );

    if ( $run->CHILD_ERROR() ) {

        # Some of the pdns utlity commands send error output to stdout (ex: secure-zone),
        # so we need to parse both.
        my $output = $run->stdout() . $run->stderr();

        $output =~ s/^.+\[bindbackend\].+\n//m;    # Strip out the 'bindbackend' parsing messages.
        $output =~ s/\n/. /g;
        $output =~ s/^\s+|\s+$//;

        require Cpanel::Logger;
        my $logger = Cpanel::Logger->new();
        $logger->info("Error encountered by “$utility” when running command: “@{ $opts_hr->{'args'} }”");
        $logger->info( $run->autopsy() . ": " . $output );

        return { 'success' => 0, 'error' => $output };
    }
    return { 'success' => 1, 'output' => $run->stdout() };
}

1;
