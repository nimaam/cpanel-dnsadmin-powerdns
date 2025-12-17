package Cpanel::NameServer::Remote::cPanel;

# cpanel - Cpanel/NameServer/Remote/cPanel.pm      Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
## no critic qw(TestingAndDebugging::RequireUseWarnings)

use cPanel::PublicAPI                             ();
use cPanel::PublicAPI::WHM                        ();
use cPanel::PublicAPI::WHM::DNS                   ();
use cPanel::PublicAPI::WHM::CachedVersion         ();
use Cpanel::StringFunc::Match                     ();
use Cpanel::StringFunc::Trim                      ();
use Cpanel::NameServer::Remote::cPanel::PublicAPI ();

use parent 'Cpanel::NameServer::Remote';

our $VERSION = '1.4';

sub new {
    my ( $class, %OPTS ) = @_;

    my $self = bless \%OPTS, $class;

    my $dnspeer        = $OPTS{'host'};
    my $user           = $OPTS{'user'};
    my $ip             = $OPTS{'ip'};
    my $pass           = $OPTS{'accesshash'} || $OPTS{'pass'};
    my $remote_timeout = $OPTS{'timeout'};

    $self->{'name'}            = $dnspeer;
    $self->{'update_type'}     = $OPTS{'update_type'};
    $self->{'local_timeout'}   = $OPTS{'local_timeout'};
    $self->{'remote_timeout'}  = $OPTS{'remote_timeout'};
    $self->{'queue_callback'}  = $OPTS{'queue_callback'};
    $self->{'output_callback'} = $OPTS{'output_callback'};

    $self->{'publicapi'} = Cpanel::NameServer::Remote::cPanel::PublicAPI->new(
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

    return $self;
}

sub getallzones {
    my ( $self, $unique_dns_request_id ) = @_;

    require Cpanel::Gzip::ungzip;
    my $zdata  = $self->{'publicapi'}->getallzones_local($unique_dns_request_id);
    my $uzdata = Cpanel::Gzip::ungzip::gunzipmem($zdata);
    $self->output( $uzdata ne '' ? $uzdata : $zdata );
    return $self->_check_action( 'get all the zones', $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

sub cleandns {
    my ( $self, $unique_dns_request_id ) = @_;
    $self->output( $self->{'publicapi'}->cleandns_local($unique_dns_request_id) );
    return $self->_check_action( 'cleanup dns', $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

sub removezone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );
    $self->output( $self->{'publicapi'}->removezone_local( $dataref->{'zone'}, $unique_dns_request_id ) . "\n" );
    return $self->_check_action( "remove the zone: $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

sub removezones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    chomp( $dataref->{'zones'} );

    $self->output( $self->{'publicapi'}->removezones_local( ( $dataref->{'zones'} || $dataref->{'zone'} ), $unique_dns_request_id ) . "\n" );
    return $self->_check_action( "remove the zone(s): " . ( $dataref->{'zones'} || $dataref->{'zone'} ), $Cpanel::NameServer::Constants::QUEUE );

}

sub reloadbind {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    $self->output( $self->{'publicapi'}->reloadbind_local( $unique_dns_request_id, $dataref->{'zone'} ) . "\n" );
    return $self->_check_action( "reload bind", $Cpanel::NameServer::Constants::QUEUE );
}

sub reloadzones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    $self->output( $self->{'publicapi'}->reloadzones_local( $unique_dns_request_id, $dataref->{'zone'} ) . "\n" );
    {
        my @check_action_results = $self->_check_action( "reload zones $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
        return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub reconfigbind {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    $self->output( $self->{'publicapi'}->reconfigbind_local($unique_dns_request_id) . "\n" );
    return $self->_check_action( "reconfig bind", $Cpanel::NameServer::Constants::QUEUE );

}

sub savezone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    $self->output( $self->{'publicapi'}->savezone_local( $dataref->{'zone'}, $dataref->{'zonedata'}, $unique_dns_request_id ) );
    return $self->_check_action( "save the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

sub synckeys {
    my ( $self, $unique_dns_request_id, $dataref, $rawdata ) = @_;
    chomp( $dataref->{'zone'} );

    $rawdata = $self->_strip_dnsuniqid($rawdata);

    $self->output( $self->{'publicapi'}->synckeys_local( $rawdata, $unique_dns_request_id ) );
    return $self->_check_action( "sync keys: $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

sub revokekeys {
    my ( $self, $unique_dns_request_id, $dataref, $rawdata ) = @_;
    chomp( $dataref->{'zone'} );

    $rawdata = $self->_strip_dnsuniqid($rawdata);

    $self->output( $self->{'publicapi'}->revokekeys_local( $rawdata, $unique_dns_request_id ) );
    return $self->_check_action( "revoke keys: $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

sub synczones {
    my ( $self, $unique_dns_request_id, $dataref, $rawdata ) = @_;
    chomp( $dataref->{'zone'} );

    $rawdata = $self->_strip_dnsuniqid($rawdata);

    local $self->{'publicapi'}->{'timeout'} = ( ( int( $self->{'local_timeout'} / 2 ) > $self->{'remote_timeout'} ) ? int( $self->{'local_timeout'} / 2 ) : $self->{'remote_timeout'} );    #allow long timeout

    $self->output( $self->{'publicapi'}->synczones_local( $rawdata, $unique_dns_request_id ) );
    return $self->_check_action( "sync zones: $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );

}

sub quickzoneadd {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    $self->output( $self->{'publicapi'}->quickzoneadd_local( $dataref->{'zone'}, $dataref->{'zonedata'}, $unique_dns_request_id ) );
    return $self->_check_action( "quick add the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

sub addzoneconf {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    $self->output( $self->{'publicapi'}->addzoneconf_local( $dataref->{'zone'}, $unique_dns_request_id ) );
    return $self->_check_action( "add the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::QUEUE );
}

sub getzone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    $self->output( $self->{'publicapi'}->getzone_local( $dataref->{'zone'}, $unique_dns_request_id ) );
    return $self->_check_action( "get the zone $dataref->{'zone'}", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

sub getzones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    chomp( $dataref->{'zones'} );

    require Cpanel::Gzip::ungzip;
    my $zdata  = $self->{'publicapi'}->getzones_local( ( $dataref->{'zones'} || $dataref->{'zone'} ), $unique_dns_request_id );
    my $uzdata = Cpanel::Gzip::ungzip::gunzipmem($zdata);
    $self->output( $uzdata ne '' ? $uzdata : $zdata );
    return $self->_check_action( "get the zones " . ( $dataref->{'zones'} || $dataref->{'zone'} ), $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

sub getzonelist {
    my ( $self, $unique_dns_request_id ) = @_;
    my @ZONES = $self->{'publicapi'}->getzonelist_local($unique_dns_request_id);

    my @check_action_results = $self->_check_action( "get the zone list", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
    return (@check_action_results) if $check_action_results[$Cpanel::NameServer::Constants::CHECK_ACTION_POSITION_STATUS] != $Cpanel::NameServer::Constants::SUCCESS;

    foreach my $zone (@ZONES) {
        if ( Cpanel::StringFunc::Match::endmatch( $zone, '.db' ) ) {
            my $cleanzone = $zone;
            $cleanzone =~ Cpanel::StringFunc::Trim::endtrim( $cleanzone, '.db' );
            $self->output( $cleanzone . "\n" );
        }
        elsif ( !Cpanel::StringFunc::Match::beginmatch( $zone, '.' ) && $zone !~ /\.\./ ) {
            $self->output( $zone . "\n" );
        }
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub zoneexists {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    chomp( $dataref->{'zone'} );
    $self->output( $self->{'publicapi'}->zoneexists_local( $dataref->{'zone'}, $unique_dns_request_id ) ? '1' : '0' );
    return $self->_check_action( "determine if the zone $dataref->{'zone'} exists", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

sub getips {
    my ( $self, $unique_dns_request_id ) = @_;
    $self->output( $self->{'publicapi'}->getips_local($unique_dns_request_id) );
    return $self->_check_action( "receive an ips list", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

sub getpath {
    my ( $self, $unique_dns_request_id ) = @_;
    $self->output( $self->{'publicapi'}->getpath_local($unique_dns_request_id) . "\n" );
    return $self->_check_action( "getpath", $Cpanel::NameServer::Constants::DO_NOT_QUEUE );
}

sub version {
    my ($self) = @_;

    my $version = $self->{'publicapi'}->version();

    $self->{'error'} = $self->{'publicapi'}->{'error'} if $self->{'publicapi'}->{'error'};

    return $version;
}

sub isatleastversion {
    my ( $reqv, $realv ) = @_;
    $realv =~ s/[\s\n]*//g;

    my @REQV  = split( /\./, $reqv );
    my @REALV = split( /\./, $realv );

    while ( $#REQV > -1 ) {
        my $creqv  = int( shift(@REQV) );
        my $crealv = int( shift(@REALV) );
        if ( $crealv > $creqv ) { return 1; }
        if ( $crealv < $creqv ) { return 0; }
    }
    return 1;
}

1;
