package Cpanel::NameServer::Remote::cPanel::PublicAPI;

# cpanel - Cpanel/NameServer/Remote/cPanel/PublicAPI.pm
#                                                  Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Cpanel::Encoder::URI  ();
use Cpanel::Sys::Hostname ();

use cPanel::PublicAPI::WHM ();

use parent 'cPanel::PublicAPI';

=encoding utf-8

=head1 NAME

Cpanel::NameServer::Remote::cPanel::PublicAPI - A wrapper to inject hosts_seen into cPanel::PublicAPI requests

=head1 SYNOPSIS

    use Cpanel::NameServer::Remote::cPanel::PublicAPI;

    my $obj = Cpanel::NameServer::Remote::cPanel::PublicAPI->new(
        'host'            => $dnspeer,
        'user'            => $user,
        'keepalive'       => 1,
        'accesshash'      => $pass,
        'debug'           => ( $OPTS{'debug'} || 0 ),
        'usessl'          => 1,
        'ssl_verify_mode' => 0,
        'timeout'         => $remote_timeout,
        ( $ip ? ( 'ip' => $ip ) : () ),
        'hosts_seen' => $OPTS{'hosts_seen'},
    );

=cut

=head2 new

Creates a Cpanel::NameServer::Remote::cPanel::PublicAPI object
which is just a thin wrapper around cPanel::PublicAPI which
requires hosts_seen

=cut

sub new {
    my ( $class, %OPTS ) = @_;

    if ( !exists $OPTS{'hosts_seen'} ) {
        die "Cpanel::NameServer::Remote::cPanel::PublicAPI requires the “hosts_seen” options.";
    }

    my $self = $class->SUPER::new(%OPTS);

    $self->{'hosts_seen'} = $OPTS{'hosts_seen'} || '';

    return $self;
}

=head2 whmreq($uri, $method, $formdata)

This is a thin wrapper around cPanel::PublicAPI::WHM
to inject “hosts_seen” into the query string or
post data.

=cut

sub whmreq {    ## no critic qw(Subroutines::RequireArgUnpacking)
    my $self   = shift;
    my $uri    = shift;
    my $method = shift;

    # Avoid shifting off the formdata to avoid a large string copy
    # $formdata = $_[0]

    my $hostname       = Cpanel::Sys::Hostname::gethostname();
    my $hosts_addition = '&hosts_seen=' . Cpanel::Encoder::URI::uri_encode_str( $self->{'hosts_seen'} . ',' . $hostname . ',' );

    if ( !$method || $method eq 'GET' ) {
        return $self->SUPER::whmreq( $uri . $hosts_addition, $method ? $method : () );
    }

    if ( index( $_[0], '&hosts_seen=' ) == -1 ) {
        return $self->SUPER::whmreq( $uri, $method, $_[0] . $hosts_addition );
    }

    my $formdata = $_[0];
    $formdata =~ s/&hosts_seen=([^&]+)//;
    my $existing_hosts_seen = $1;
    if ($existing_hosts_seen) {
        $hosts_addition .= $existing_hosts_seen;
    }
    return $self->SUPER::whmreq( $uri, $method, $formdata . $hosts_addition );
}

sub synckeys_local {
    my ( $self, $formdata, $dnsuniqid ) = @_;
    return $self->_additional_formdata_request( 'synckeys_local', $formdata, $dnsuniqid );
}

sub revokekeys_local {
    my ( $self, $formdata, $dnsuniqid ) = @_;
    return $self->_additional_formdata_request( 'revokekeys_local', $formdata, $dnsuniqid );
}

sub _additional_formdata_request {
    my ( $self, $action, $formdata, $dnsuniqid ) = @_;

    cPanel::PublicAPI::_init() if !exists $cPanel::PublicAPI::CFG{'init'};
    $formdata =~ s/\&$//g;    # formdata must come pre encoded.
    $formdata .= '&dnsuniqid=' . $cPanel::PublicAPI::CFG{'uri_encoder_func'}->($dnsuniqid);
    my $page = join( "\n", $self->whmreq( "/scripts2/$action", 'POST', $formdata ) );
    return if $self->{'error'};
    return $page;
}

1;
