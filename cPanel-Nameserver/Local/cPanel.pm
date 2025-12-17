package Cpanel::NameServer::Local::cPanel;

# cpanel - Cpanel/NameServer/Local/cPanel.pm       Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Cpanel::Context                      ();
use Cpanel::PwCache                      ();
use Cpanel::NameServer::Utils::BIND      ();
use Cpanel::NameServer::Conf             ();
use Cpanel::NameServer::Constants        ();
use Cpanel::Validate::Domain::Tiny       ();
use Cpanel::StringFunc::Match            ();
use Cpanel::ServerTasks                  ();
use Cpanel::DnsUtils::RNDCQueue::Adder   ();
use Cpanel::DNSLib::Find                 ();
use Cpanel::Logger                       ();
use Cpanel::Sys::Hostname                ();
use Cpanel::LoadModule                   ();
use Cpanel::Exception                    ();
use Cpanel::Validate::Domain::Normalize  ();
use Cpanel::Encoder::URI                 ();
use Cpanel::NameServer::DNSSEC::SyncKeys ();

use Try::Tiny;

use parent qw(Cpanel::NameServer::Local);

my $VERSION = '5.1';    #must be quoted

my $ZONES_PER_SYNCZONES_BATCH_WRITE = 256;    # Needs to be able to open 256 files at once

my $MIN_TIME_BETWEEN_RECONFIG = 7;

sub new {
    my ( $class, %OPTS ) = @_;
    my $self = bless {}, $class;

    my $dnspeer = $OPTS{'host'};

    $self->{'now'}              = $OPTS{'now'} || time();
    $self->{'name'}             = $dnspeer;
    $self->{'update_type'}      = $OPTS{'update_type'};
    $self->{'local_timeout'}    = $OPTS{'local_timeout'};
    $self->{'output_callback'}  = $OPTS{'output_callback'};
    $self->{'logger'}           = $OPTS{'logger'};
    $self->{'deferred_restart'} = $OPTS{'deferred_restart'} || 1;    # Restart right away (1s) if not enabled
    $self->{'bind_disabled'}    = $OPTS{'bind_disabled'};
    $self->{'shorthost'}        = $OPTS{'shorthost'} || Cpanel::Sys::Hostname::shorthostname();
    $self->{'hostname'}         = $OPTS{'hostname'}  || Cpanel::Sys::Hostname::gethostname();
    $self->{'dnspeers'}         = $OPTS{'dnspeers'};
    $self->{'namedconf_obj'}    = Cpanel::NameServer::Conf->new();
    $self->{'namedconf_obj'}->initialize();

    return $self;
}

sub deferred_restart_time {
    return $_[0]->{'deferred_restart'};
}

# TESTED - 1/17/2011 jnk
sub cleanup {
    my $self = shift;
    if ( $self->{'namedconf_obj'} && $self->{'namedconf_obj'}->{'dirty'} ) { $self->{'namedconf_obj'}->makeclean(); }
    return;
}

# TESTED - 1/17/2011 jnk
sub getzonelist {
    my ($self) = @_;

    $self->{'namedconf_obj'}->check_zonedir_cache();

    local $!;

    my $zonedir = $self->{'namedconf_obj'}->{'config'}->{'zonedir'};

    opendir( my $zonedir_dh, $zonedir ) or do {
        my $msg = "Failed to open zone directory “$zonedir” ($!)";
        _logger_warn($msg);
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, $msg );
    };

    my $out = join( "\n", map { m/^\./ ? () : ( $_ =~ s/\.db$// ? $_ : () ) } readdir($zonedir_dh) ) . "\n";    ## no critic qw(ControlStructures::ProhibitMutatingListFunctions)

    if ($!) {
        my $msg = "Failed to read zone directory “$zonedir” ($!)";
        _logger_warn($msg);
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, $msg );
    }

    $self->output($out);

    closedir($zonedir_dh);

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED - 1/17/2011 jnk
sub _doaddzoneconf {
    my ( $self, $zone ) = @_;
    $zone = Cpanel::Validate::Domain::Normalize::normalize($zone);

    my ( $sane, $sanity_msg ) = $self->_zone_is_sane($zone);
    if ( !$sane ) {
        $self->output($sanity_msg);
        return;
    }

    my $namedconf = $self->{'namedconf_obj'}->{'namedconffile'};

    # addzone may return false if the zone already exists, but doaddzoneconf
    # considers this to be success
    unless ( $self->{'namedconf_obj'}->addzone($zone) || $self->_checkzoneinconf( $zone, 1 ) ) {
        return 0;
    }
    my ( $chrootdir, $binduser, $bindgroup ) = Cpanel::NameServer::Utils::BIND::find_chrootbinddir();
    if ( $chrootdir ne '' ) {
        _load_modules_needed_for_chroot_copy_chown();
        Cpanel::FileUtils::Copy::safecopy( $namedconf, $chrootdir . $namedconf );
        Cpanel::SafetyBits::Chown::safe_chown_guess_gid( $binduser, $chrootdir . $namedconf );
    }

    return 1;
}

# TESTED - 1/17/2011 jnk
sub _zone_is_sane {
    my $self = shift;
    my $zone = shift;

    return ( 0, "Invalid Domain name" )        if !Cpanel::Validate::Domain::Tiny::validdomainname($zone);
    return ( 0, "Zones may not begin with ." ) if ( !$zone || Cpanel::StringFunc::Match::beginmatch( $zone, '.' ) || $zone =~ /\.\./ );

    if ( length($zone) > 254 ) {
        return ( 0, "Zone name is too large.  The maximum length is 254 characters!" );
    }
    return ( 1, 'Zone is sane' );
}

# TESTED - 1/17/2011 jnk
sub _checkzoneinconf {
    my $self             = shift;
    my $zone             = shift;
    my $skip_cache_cache = shift;

    return $self->{'namedconf_obj'}->haszone( $zone, $skip_cache_cache );
}

# TESTED - 1/17/2011 jnk
sub zoneexists {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    $self->{'namedconf_obj'}->check_zonedir_cache();
    $self->output( $self->_zoneexists( $dataref->{'zone'} ) );

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );

}

# TESTED - 1/17/2011 jnk
# If confcheck == 1 then we ONLY check the conf
# IF confcheck == 0 then we check the CONF and the ZONE
sub _zoneexists {
    my ( $self, $zone, $confcheck ) = @_;

    return 0 unless defined($zone) && $zone ne '';

    chomp($zone) if $zone;

    my $zonedir = $self->{'namedconf_obj'}->{'config'}->{'zonedir'};

    return 1 if ( !$confcheck && -e $zonedir . '/' . $zone . '.db' );

    $self->{'namedconf_obj'}->checkcache();

    return 1 if ( $self->_checkzoneinconf($zone) );

    #search for an entry in any higher level zone
    my @ZSUB;
    my @ZBREAK = split( /\./, $zone );
    while ( $#ZBREAK > 0 ) {
        my $sub      = shift(@ZBREAK);
        my $zonefile = join( '.', @ZBREAK );

        push( @ZSUB, $sub );
        my $subsearch = join( '.', @ZSUB );

        if ( !$confcheck && -e $zonedir . '/' . $zonefile . '.db' ) {
            my $foundzone = 0;
            foreach ( split( /\n/, $self->_cached_zone_fetch( $zonedir, $zonefile, { 'no_warnings' => 1 } ) ) ) {    # zone may not exist

                # sub domain is added either as a FQDN with a dot, or
                # just the sub domain name without a dot
                if ( m/^\s*\Q${subsearch}\E\s+/ || m/^\s*\Q${zone}\E\.\s+/ ) {
                    $foundzone = 1;
                    last;
                }
            }
            if ($foundzone) {
                return 1;
            }
        }
    }

    return 0;
}

# TESTED - 1/17/2011 jnk
sub cleandns {
    my ($self) = @_;

    require Cpanel::SafeRun::Errors;
    $self->output( Cpanel::SafeRun::Errors::saferunallerrors('/usr/local/cpanel/scripts/cleandns') );

    my $ok = ( $? >> 8 == 0 ) ? 1 : 0;

    if ($ok) {
        return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
    }
    else {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Failed to cleandns on $self->{'shorthost'}" );
    }
}

# TESTED - 1/17/2011 jnk
sub getpath {
    my ($self) = @_;

    require Cpanel::DNSLib::Config;
    foreach my $dnspeer ( @{ $self->{'dnspeers'} } ) {
        my ($host) = Cpanel::DNSLib::Config::getclusteruserpass($dnspeer);    # do user should be given
        $host ||= $dnspeer;
        print STDERR "GETPATH for $dnspeer: $self->{'hostname'} $host\n" if $self->{'debug'};
        $self->output("$self->{'hostname'} $host\n");
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );

}

*removezone = *removezones;

# TESTED - 1/17/2011 jnk
sub removezones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;
    my %ZONELIST;

    chomp( $dataref->{'zone'} )  if exists $dataref->{'zone'}  && defined $dataref->{'zone'};
    chomp( $dataref->{'zones'} ) if exists $dataref->{'zones'} && defined $dataref->{'zones'};

    foreach my $zone ( split( /\,/, ( $dataref->{'zones'} || $dataref->{'zone'} ) ) ) {
        $zone =~ s/^\s*|\s*$//g;
        $ZONELIST{$zone} = 1;
    }
    $self->{'namedconf_obj'}->check_zonedir_cache();

    my $zonedir = $self->{'namedconf_obj'}->{'config'}->{'zonedir'};
    my ( $chrootdir, $binduser, $bindgroup ) = Cpanel::NameServer::Utils::BIND::find_chrootbinddir();

    my %ZONES_TO_REMOVE = %ZONELIST;

    my @zones_deleted_from_conf = $self->{'namedconf_obj'}->removezones( keys %ZONELIST );
    delete @ZONES_TO_REMOVE{@zones_deleted_from_conf};
    my $changecount = scalar @zones_deleted_from_conf;
    if ( $changecount && $chrootdir ) {
        _load_modules_needed_for_chroot_copy_chown();
        Cpanel::FileUtils::Copy::safecopy( $self->{'namedconf_obj'}->{'namedconffile'}, $chrootdir . $self->{'namedconf_obj'}->{'namedconffile'} );
        Cpanel::SafetyBits::Chown::safe_chown_guess_gid( $binduser, $chrootdir . $self->{'namedconf_obj'}->{'namedconffile'} );
    }

    require Cpanel::DNSLib::Zone;
    foreach my $zone ( keys %ZONELIST ) {
        if ( Cpanel::DNSLib::Zone::removezone( $zone, $zonedir, $chrootdir ) ) {
            $changecount++;
            delete $ZONES_TO_REMOVE{$zone};
            $self->output("$zone => deleted from $self->{'shorthost'}. \n");
        }
    }
    if ($changecount) {

        # we dont need this on PowerDNS as the removezone() takes cares of it.
        return $self->_reconfig_bind() if $self->{'namedconf_obj'}->type() ne 'powerdns';
    }
    if ( scalar keys %ZONES_TO_REMOVE ) {
        my $zones = join( ",", sort keys %ZONES_TO_REMOVE );
        my $s     = scalar keys %ZONES_TO_REMOVE > 1 ? 's' : '';
        $self->output("Unable to remove zone$s: “$zones” on $self->{'shorthost'}.\n");
    }

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );

}

# When a zone is specified reloadbind() will be fastest if it was previously in named.conf
#
# When the zone is new or removed reconfigbind() will be fastest
#
# When we don't know what changed, reloadbind() with no zone specified is safest

# TESTED - 1/17/2011 jnk

sub reloadbind {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    return if $self->{'bind_disabled'};

    $dataref->{'zone'}  =~ s/[\r\n\f]+//g if exists $dataref->{'zone'}  && $dataref->{'zone'};
    $dataref->{'zones'} =~ s/[\r\n\f]+//g if exists $dataref->{'zones'} && $dataref->{'zones'};

    if ( $self->{'namedconf_obj'}->can('reload') ) {
        my $ret = $self->{'namedconf_obj'}->reload( $dataref->{'zones'} || $dataref->{'zone'}, $self );
        return $ret->{'success'} ? @{$ret}{ 'success', 'output' } : @{$ret}{ 'success', 'error' };
    }

    my ( $rndc, $rndcprog ) = Cpanel::DNSLib::Find::find_rndc();
    if ( !defined $rndc || $rndc eq '' ) {
        $self->output("Fatal, neither rndc or ndc was found on this server ($self->{'shorthost'}).\n");
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Fatal, neither rndc or ndc was found on this server ($self->{'shorthost'})." );
    }
    if ( !$dataref->{'zones'} && !$dataref->{'zone'} ) {
        return $self->_reloadbindlocal_nozones( $rndc, $rndcprog );
    }

    $self->{'namedconf_obj'}->checkcache();
    my @OK_RELOAD;
    my %ZONELIST;
    foreach my $zone ( split( /\,/, ( $dataref->{'zones'} || $dataref->{'zone'} ) ) ) {
        $ZONELIST{$zone} = 0;
    }

    $self->{'namedconf_obj'}->check_zonedir_cache();
    foreach my $zone ( keys %ZONELIST ) {
        if ( $self->_zoneexists( $zone, 0 ) ) {
            push @OK_RELOAD, $zone;
        }
        else {
            $self->output("Skipping reload of zone: $zone as it does not exist on $self->{'shorthost'}.\n");
        }
    }

    if (@OK_RELOAD) {
        my $viewcount = $self->{'namedconf_obj'}->viewcount($Cpanel::NameServer::Conf::BIND::SKIP_CACHE_CHECK);
        my @viewslist = ( $viewcount > 0 ) ? $self->{'namedconf_obj'}->getviews($Cpanel::NameServer::Conf::BIND::SKIP_CACHE_CHECK) : ('full');
        my $err;

        try {
            foreach my $view ( sort { return ( $a =~ m/^extern/i ) ? -1 : ( $b =~ m/^extern/i ) ? 1 : $a cmp $b; } @viewslist ) {
                next unless $view;

                # Do not bother to check to see if the zones in the view as this is more expensive than
                # just trying to reload it and can lead to a build up of reloadzones processes which
                # can starve the system for memory
                #
                # With the viewfilter check
                # spent 186s (115µs+186) within Cpanel::NameServer::Local::cpanel::reloadbind which was called:
                #
                # Without the viewfilter check
                # spent 75.3ms (106µs+75.2) within Cpanel::NameServer::Local::cpanel::reloadbind which was called:
                #
                # root     17039  0.1  0.1 208656 39716 ?        S    18:15   0:00 dnsadmin - RELOADZONES - ORUMOKUn7662oahTAUxoLg3TCRomK2QP_1563819332 (LOCAL) - waiting for lock
                # root     17065  0.1  0.1 208660 39716 ?        S    18:15   0:00 dnsadmin - RELOADZONES - Gexk903kRHUTb2OOlK8k9FBHgwXAjSqu_1563819334 (LOCAL) - waiting for lock
                # ....
                # root     17243  0.1  0.1 208656 39716 ?        S    18:15   0:00 dnsadmin - RELOADZONES - NRvQwsLbaSaIo7LZmcX2xhxe2uOokeop_1563819351 (LOCAL) - waiting for lock
                #
                # The side effect is that zones that are missing from a view will show an error in the queueprocd.log
                # In the past this would have been a problem because it would cause a fallback to a full reload, however
                # since this is all done via a taskqueue module this is not an issue.  Also the zones is ACTUALLY missing
                # from the view so we should be throwing an error.
                #
                foreach my $zone (@OK_RELOAD) {
                    Cpanel::DnsUtils::RNDCQueue::Adder->add( $viewcount ? "reload $zone IN $view" : "reload $zone" );
                }
            }

            Cpanel::ServerTasks::schedule_task( ['BINDTasks'], $self->{'deferred_restart'}, 'rndc_queue' );
        }
        catch {
            $err = $_;
        };

        if ($err) {
            my $error_msg = "Error reloading zones “@OK_RELOAD” on $self->{'shorthost'}: $err";
            $self->output("$error_msg\n");
            _logger_warn($error_msg);

            # Full reload -- We break out of the zones and views loops at this point
            return $self->_reloadbindlocal_nozones( $rndc, $rndcprog );
        }

    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

*reloadzones = *reloadbind;

sub _reloadbindlocal_nozones {
    my $self = shift;

    # This function assumes the nsd/bind/disabled validation has already taken place
    # Pass in $rndc and $rndcprog to avoid searching for them

    my $rndc     = shift;
    my $rndcprog = shift;
    unless ( $rndc && $rndcprog ) {
        ( $rndc, $rndcprog ) = Cpanel::DNSLib::Find::find_rndc();
    }

    my $err;
    try {
        Cpanel::DnsUtils::RNDCQueue::Adder->add('reload');
        Cpanel::ServerTasks::schedule_task( ['BINDTasks'], $self->{'deferred_restart'}, 'rndc_queue' );
    }
    catch {
        $err = $_;
    };

    if ($err) {
        $self->output("Error reloading bind on $self->{'shorthost'}: $err\n");
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Error reloading bind on $self->{'shorthost'}: $err" );
    }
    $self->output("Bind reloading on $self->{'shorthost'} using ${rndcprog}\n");
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );

}

# TESTED - 1/17/2011 jnk
sub reconfigbind {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp $dataref->{'zone'} if $dataref->{'zone'};

    return $self->_reconfig_bind( $dataref->{'zone'} );
}

#
sub _reconfig_bind {
    my ( $self, $zone ) = @_;

    return if $self->{'bind_disabled'};

    # Generic pluggable logic -- PDNS currently
    if ( $self->{'namedconf_obj'}->can('reconfig') && $self->{'namedconf_obj'}->type() ne 'bind' ) {
        if ( $self->{'namedconf_obj'}->reconfig( $zone, $self )->{'success'} ) {
            return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
        }
        else {
            return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Error reconfiguring " . $self->{'namedconf_obj'}->type() );
        }
    }

    # legacy BIND specific logic
    my $err;
    try {
        my $rndc_reconfig_time = $self->{'deferred_restart'};
        if ( $rndc_reconfig_time < $MIN_TIME_BETWEEN_RECONFIG ) {
            $rndc_reconfig_time = $MIN_TIME_BETWEEN_RECONFIG;
        }
        Cpanel::DnsUtils::RNDCQueue::Adder->add('reconfig');
        Cpanel::ServerTasks::schedule_task( ['BINDTasks'], $self->{'deferred_restart'}, 'rndc_queue' );
    }
    catch {
        $err = $_;
    };
    if ($err) {
        $self->output("Error reconfiguring bind on $self->{'shorthost'}: $err\n");
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Error reconfiguring bind on $self->{'shorthost'}: $err" );
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED - 1/17/2011 jnk
sub savezone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );

    #needed to get the zone dir ONLY
    $self->{'namedconf_obj'}->check_zonedir_cache();

    my $zonedir   = $self->{'namedconf_obj'}->{'config'}->{'zonedir'};
    my $zone      = $dataref->{'zone'};
    my $checkzone = $self->{'checkzone'};

    $zone = Cpanel::Validate::Domain::Normalize::normalize($zone);

    my ( $sane, $sanity_msg ) = $self->_zone_is_sane($zone);
    if ( !$sane ) {
        $self->output($sanity_msg);
        return;
    }

    if ( !$dataref->{'zonedata'} ) {
        $self->output("Missing zonedata, cannot save zone on $self->{'shorthost'}\n");
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Unable to save zone $zone with zonedata on $self->{'shorthost'}" );
    }

    if ($checkzone) {
        my ( $status, $message ) = _checkzone( $zonedir, $zone, $dataref->{'zonedata'} );
        if ( !$status ) {
            my $error_msg = "Attempt to save zone $zone failed. New zone contains errors: $message on $self->{'shorthost'}";
            _logger_warn($error_msg);
            return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, $error_msg );
        }
    }

    Cpanel::LoadModule::load_perl_module('Cpanel::ZoneFile::Transaction');    # dnsadmin already loads but other things do not need it
    my $error_msg;
    try {
        Cpanel::ZoneFile::Transaction::write_zone_file( $zonedir, $zone, $dataref->{'zonedata'} );
    }
    catch {
        $error_msg = "Unable to save zone $zone: " . Cpanel::Exception::get_string($_) . " on $self->{'shorthost'}";
    };
    if ($error_msg) {
        _logger_warn($error_msg);
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, $error_msg );
    }

    if ( !$self->{'uid'} ) { $self->_load_uid_gid(); }
    if ( $self->{'uid'} && $self->{'gid'} ) {
        chown( $self->{'uid'}, $self->{'gid'}, $zonedir . '/' . $zone . '.db' );
    }

    if ( $self->{'namedconf_obj'}->can('savezone') ) {
        my $run = $self->{'namedconf_obj'}->savezone( $zone, $dataref->{'zonedata'}, $checkzone );

        unless ( $run->{'success'} ) {
            return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Unable to update $zone on $self->{'shorthost'}: $run->{'error'}" );
        }
    }

    my ( $chrootdir, $binduser, $bindgroup ) = Cpanel::NameServer::Utils::BIND::find_chrootbinddir();
    if ($chrootdir) {
        _load_modules_needed_for_chroot_copy_chown();
        Cpanel::FileUtils::Copy::safecopy( $zonedir . '/' . $zone . '.db', $chrootdir . $zonedir . '/' . $zone . '.db' );
        Cpanel::SafetyBits::Chown::safe_chown_guess_gid( $binduser, $chrootdir . $zonedir . '/' . $zone . '.db' );
    }

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

sub synckeys {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    my $zone = $dataref->{zone};

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, 'No zone was specificed to sync.' ) if !$zone;

    my %keydata = map {
        $_ => {
            'data' => $dataref->{$_},
            'type' => ( $dataref->{$_} =~ /^;([CKZ]SK)/ )[0],
        }
    } grep { length && !tr{0-9}{}c } keys %$dataref;

    if ( !keys %keydata ) {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "No valid DNSSEC keys found in request for zone $zone" );
    }

    $keydata{nsec} = $dataref->{nsec} if $dataref->{nsec};

    my $dnssec = Cpanel::NameServer::DNSSEC::SyncKeys->new($zone);

    if ( $dnssec->activate_keys( \%keydata ) ) {
        return ( $Cpanel::NameServer::Constants::SUCCESS, "DNSSEC keys activated for zone $zone." );
    }

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Errors encoutered when activating keys for zone $zone." );
}

sub revokekeys {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    my $zone = $dataref->{zone};

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, 'Missing the zone to remove keys.' ) if !$zone;

    my $dnssec = Cpanel::NameServer::DNSSEC::SyncKeys->new($zone);

    if ( $dnssec->delete_keys($dataref) ) {
        return ( $Cpanel::NameServer::Constants::SUCCESS, "DNSSEC keys deleted form zone $zone" );
    }

    return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Failed to delete DNSSEC keys from zone $zone" );
}

# TESTED - 1/17/2011 jnk
sub synczones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    my $checkzone = $self->{'checkzone'};
    $self->{'namedconf_obj'}->checkcache();
    my $zonedir = $self->{'namedconf_obj'}->{'config'}->{'zonedir'};

    if ( !$self->{'uid'} ) { $self->_load_uid_gid(); }
    my ( $chrootdir, $binduser, $bindgroup ) = Cpanel::NameServer::Utils::BIND::find_chrootbinddir();

    my @new_zones        = ();
    my @zones_to_process = grep { index( $_, 'cpdnszone' ) > -1 } keys %$dataref;
    my @keys_to_process  = grep { index( $_, 'cpdnskey' ) > -1 } keys %$dataref;
    Cpanel::LoadModule::load_perl_module('Cpanel::ZoneFile::Transaction');    # dnsadmin already loads but other things do not need it
    while ( my @zone_batch = splice( @zones_to_process, 0, $ZONES_PER_SYNCZONES_BATCH_WRITE ) ) {

        foreach my $zonename (@zone_batch) {
            next if $zonename !~ m/^cpdnszone-.+/;
            my $zone = $zonename;
            $zone =~ s/^cpdnszone-//g;
            next if ( !$zone || $zone =~ m/^\./ || $zone =~ m/\.\./ );
            if ( !Cpanel::Validate::Domain::Tiny::validdomainname($zone) ) {
                next;
            }

            if ($checkzone) {
                _checkzone_and_log( $zonedir, $zone, $dataref->{$zonename} ) or next;
            }
            my ($err);
            try {
                Cpanel::ZoneFile::Transaction::write_zone_file( $zonedir, $zone, $dataref->{$zonename} );
            }
            catch {
                $err = $_;
                _logger_warn( "Unable to save zone $zone: " . Cpanel::Exception::get_string($err) );
            };

            if ( $self->{'uid'} && $self->{'gid'} ) {
                chown( $self->{'uid'}, $self->{'gid'}, $zonedir . '/' . $zone . '.db' );
            }
            if ($chrootdir) {
                _load_modules_needed_for_chroot_copy_chown();
                Cpanel::FileUtils::Copy::safecopy( $zonedir . '/' . $zone . '.db', $chrootdir . $zonedir . '/' . $zone . '.db' );
                Cpanel::SafetyBits::Chown::safe_chown_guess_gid( $binduser, $chrootdir . $zonedir . '/' . $zone . '.db' );
            }

            #
            # The namedconf_obj needs to be told
            # about saving the zone.  This was accidentially removed
            # in an earlier refactor.
            #
            # At the time of this comment MyDNS (now removed from the product) was the only
            # module to implement this since it stores the
            # zone data outside of /var/named
            #
            if ( $self->{'namedconf_obj'}->can('savezone') ) {
                try {
                    unless ( $self->{'namedconf_obj'}->savezone( $zone, $dataref->{$zonename}, $checkzone )->{'success'} ) {
                        _logger_warn("Unable to save zone $zone");
                    }
                }
                catch {
                    $err = $_;
                    _logger_warn( "Unable to save zone $zone: " . Cpanel::Exception::get_string($err) );
                };
            }
            if ($err) {
                next;
            }

            # Force lookup in local named.conf for zone entry
            if ( !$self->_checkzoneinconf( $zone, 1 ) ) {
                push @new_zones, $zone;
            }
        }
    }

    if ( scalar @new_zones ) {
        $self->{'namedconf_obj'}->addzones(@new_zones);
        my $namedconf = $self->{'namedconf_obj'}->{'namedconffile'};
        my ( $chrootdir, $binduser, $bindgroup ) = Cpanel::NameServer::Utils::BIND::find_chrootbinddir();
        if ( length $chrootdir ) {
            _load_modules_needed_for_chroot_copy_chown();
            Cpanel::FileUtils::Copy::safecopy( $namedconf, $chrootdir . $namedconf );
            Cpanel::SafetyBits::Chown::safe_chown_guess_gid( $binduser, $chrootdir . $namedconf );
        }
        if ( scalar @new_zones == 1 ) {

            # 1 zone, just reconfig it (bind reconfigs everything anyways)
            $self->_reconfig_bind( $new_zones[0] );
        }
        else {
            # multiple zones, do a full reconfig (bind reconfigs everything anyways)
            $self->_reconfig_bind();
        }
    }

    _activate_dnssec_keys( $dataref, @keys_to_process ) if @keys_to_process;

    if ( $self->{'namedconf_obj'}->can('post_synczones') ) {
        unless ( $self->{'namedconf_obj'}->post_synczones() ) {
            _logger_warn("Unable to run post_synczones.");
        }
    }

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );

}

# TESTED - 1/17/2011 jnk
sub quickzoneadd {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );
    my $zone = Cpanel::Validate::Domain::Normalize::normalize( $dataref->{'zone'} );
    my ( $sane, $sanity_msg ) = $self->_zone_is_sane($zone);
    if ( !$sane ) {
        $self->output($sanity_msg);
        return;
    }

    unless ( exists $dataref->{'zonedata'} ) {
        $self->output("No zone data supplied to quickzoneadd on $self->{'shorthost'}\n");
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "No zone data supplied to quickzoneadd on $self->{'shorthost'}" );
    }

    # Write the zone file before updating named.conf in case rndc reconfig
    # or a restart happens in order to ensure the zone file is already there
    # as soon as named.conf is updated
    unless ( ( $self->savezone( $unique_dns_request_id, $dataref ) )[0] == $Cpanel::NameServer::Constants::SUCCESS ) {
        my $err_msg = "Could not store zonedata for $dataref->{'zone'} on $self->{'shorthost'}\n";
        unless ( $self->{'namedconf_obj'}->removezone( $dataref->{'zone'} ) ) {
            $err_msg .= "Could not remove $dataref->{'zone'} from the Bind configuration (named.conf) on $self->{'shorthost'}\n";
            $err_msg .= "Configuration may be in an inconsistent state on $self->{'shorthost'}\n";
        }
        $self->output($err_msg);
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, $err_msg );
    }
    if ( !$self->_doaddzoneconf( $dataref->{'zone'} ) ) {
        $self->output("Unable to add zone $dataref->{'zone'} to the Bind configuration (named.conf) on $self->{'shorthost'}\n");
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Unable to add zone $dataref->{'zone'} to the Bind configuration (named.conf) on $self->{'shorthost'}" );
    }

    # Full (expensive) reread of named.conf required
    $self->_reconfig_bind( $dataref->{'zone'} ) if $self->{'namedconf_obj'}->type() ne 'powerdns';    # we dont need this on PowerDNS as the addzone() takes cares of it.

    # calling program can parse STDOUT and look for 'success'
    $self->output("Zone $dataref->{'zone'} has been successfully added\n");

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED - 1/17/2011 jnk
sub addzoneconf {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    chomp( $dataref->{'zone'} );
    if ( $self->_doaddzoneconf( $dataref->{'zone'} ) ) {
        return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );

    }
    else {
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, "Failed to add the zone: $dataref->{'zone'} on $self->{'shorthost'}" );
    }

}

# TESTED - 1/17/2011 jnk
sub getzone {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    my $zone = $dataref->{'zone'};
    $zone =~ s/\///g;

    $self->{'namedconf_obj'}->check_zonedir_cache();
    my $zonedir = $self->{'namedconf_obj'}->{'config'}->{'zonedir'};
    $self->output( $self->_cached_zone_fetch( $zonedir, $zone, { 'no_warnings' => 1 } ) );

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );

}

# TESTED - 1/17/2011 jnk
sub getzones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    $dataref->{'zone'}  =~ s/[\r\n\f]+//g if exists $dataref->{'zone'}  && $dataref->{'zone'};
    $dataref->{'zones'} =~ s/[\r\n\f]+//g if exists $dataref->{'zones'} && $dataref->{'zones'};

    $self->{'namedconf_obj'}->check_zonedir_cache();

    my $zonedir = $self->{'namedconf_obj'}->{'config'}->{'zonedir'};

    my %NEEDEDZONES = map { tr{/}{}dr => 1; } split( /\,/, ( $dataref->{'zones'} || $dataref->{'zone'} ) );

    my $need_dnssec_keys = $dataref->{keys} // 0;

    # No need to check if its value here because we already prevent the directory
    # traversal by removing the /
    require Cpanel::NameServer::DNSSEC::Cache;
    my $output = '';
    foreach my $zone ( grep { -e $zonedir . '/' . $_ . '.db' } keys %NEEDEDZONES ) {
        $output .= $self->_fetch_uri_encoded_zone( $zonedir, $zone );
        if ( $need_dnssec_keys && Cpanel::NameServer::DNSSEC::Cache::has_dnssec($zone) ) {
            $output .= _fetch_uri_encoded_keys($zone);
        }
    }

    $self->output($output);

    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED - 1/17/2011 jnk
sub getallzones {
    my ( $self, $unique_dns_request_id, $dataref ) = @_;

    $self->{'namedconf_obj'}->check_zonedir_cache();
    my $zonedir = $self->{'namedconf_obj'}->{'config'}->{'zonedir'};

    opendir( my $zonedir_dh, $zonedir ) or do {
        my $msg = "opendir($zonedir): $!";
        $self->{'logger'} ||= Cpanel::Logger->new($msg);
        $self->{'logger'}->warn($msg);
        return ( $Cpanel::NameServer::Constants::ERROR_GENERIC_LOGGED, $msg );
    };

    my $output = '';

    require Cpanel::NameServer::DNSSEC::Cache;
    my $need_dnssec_keys = $dataref->{keys} // 0;

    my ( $zone, $disknode );
    for $disknode ( readdir $zonedir_dh ) {
        next if index( $disknode, '.' ) == 0;
        next if rindex( $disknode, '.db' ) ne length($disknode) - 3;

        $zone = substr( $disknode, 0, -3 );
        next if !Cpanel::Validate::Domain::Tiny::validdomainname($zone);

        $output .= $self->_fetch_uri_encoded_zone( $zonedir, $zone );
        if ( $need_dnssec_keys && Cpanel::NameServer::DNSSEC::Cache::has_dnssec($zone) ) {
            $output .= _fetch_uri_encoded_keys($zone);
        }
    }

    $self->output($output);

    closedir($zonedir_dh);
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );
}

# TESTED - 1/17/2011 jnk
sub getips {
    my ($self) = @_;

    require Cpanel::NAT;
    if ( Cpanel::NAT::is_nat() ) {
        $self->output("$_\n") foreach @{ Cpanel::NAT::get_all_public_ips() };
    }

    require Cpanel::DIp::MainIP;
    require Cpanel::Ips;
    my $mainip    = Cpanel::DIp::MainIP::getmainip();
    my $ifcfg     = Cpanel::Ips::fetchifcfg();
    my ($netmask) = map { $_->{mask} } grep { $_->{ip} eq $mainip } @$ifcfg;
    if ( $mainip && $netmask ) {
        my $ipinfo = {};
        my ($return) = Cpanel::Ips::get_ip_info( $mainip, $netmask, $ipinfo );
        $self->output("$mainip:$netmask:$ipinfo->{'broadcast'}\n") if $return;
    }

    if ( open( my $ips_fh, '<', '/etc/ips' ) ) {
        local $/;
        $self->output( readline($ips_fh) );
        close($ips_fh);
    }
    return ( $Cpanel::NameServer::Constants::SUCCESS, 'OK' );

}

# TESTED - 1/17/2011 jnk
sub _load_uid_gid {
    my $self = shift;

    my ( $chrootdir, $binduser, $bindgroup ) = Cpanel::NameServer::Utils::BIND::find_chrootbinddir();

    return ( ( undef, undef, $self->{'uid'}, $self->{'gid'} ) = Cpanel::PwCache::getpwnam($binduser) );
}

# TESTED - 1/17/2011 jnk
sub _cached_zone_fetch {
    my ( $self, $zonedir, $zone, $options ) = @_;

    Cpanel::LoadModule::load_perl_module('Cpanel::ZoneFile::Transaction');    # dnsadmin already loads but other things do not need it
    my ( $zone_obj_ref, $err );
    try {
        $zone_obj_ref = Cpanel::ZoneFile::Transaction::read_zone_file( $zonedir, $zone );
    }
    catch {
        $err = $_;
    };
    if ( $err || !$zone_obj_ref ) {
        if ( !$options->{'no_warnings'} ) {
            _logger_warn( "_cached_zone_fetch: Could not read from zonefile $zone: " . Cpanel::Exception::get_string($err) );
        }
        return '';
    }
    return $zone_obj_ref if $options->{'full_fetch'};
    return $zone_obj_ref->{'zonedata'};
}

# TESTED - 1/17/2011 jnk
sub _fetch_uri_encoded_zone {
    my ( $self, $zonedir, $zone ) = @_;

    if ( my $zone_obj = $self->_cached_zone_fetch( $zonedir, $zone, { 'full_fetch' => 1 } ) ) {
        return ( 'cpdnszone-' . $zone_obj->{'encoded_zone'} . '=' . $zone_obj->{'encoded_zonedata'} . '&' );
    }
    return '';
}

sub get_zone_last_modify_time {
    my $self = shift;
    my $zone = shift;

    $self->{'namedconf_obj'}->check_zonedir_cache();
    my $zonedir       = $self->{'namedconf_obj'}->{'config'}->{'zonedir'};
    my $zone_data_ref = $self->_cached_zone_fetch( $zonedir, $zone, { 'full_fetch' => 1 } );

    return $zone_data_ref->{'mtime'} || 0;
}

sub _logger_warn {
    my ($message) = @_;
    return Cpanel::Logger::logger(
        {
            'message'   => $message,
            'level'     => 'warn',
            'service'   => 'dnsadmin',
            'output'    => 2,
            'backtrace' => 1,
        }
    );
}

sub _checkzone {
    my ( $zonedir, $zone, $zonedata ) = @_;

    require Cpanel::Rand;
    Cpanel::Context::must_be_list();
    my ( $tmp_file, $tmp_fh ) = Cpanel::Rand::get_tmp_file_by_name( $zonedir . '/' . $zone . '.db' );
    print {$tmp_fh} $zonedata;
    close($tmp_fh);

    require Cpanel::DNSLib::Zone;
    return Cpanel::DNSLib::Zone::checkzone( $zone, $tmp_file );
}

sub _checkzone_and_log {
    my ( $zonedir, $zone, $zonedata ) = @_;

    my ( $status, $message ) = _checkzone( $zonedir, $zone, $zonedata );
    if ( !$status ) {
        _logger_warn("Attempt to check zone $zone failed. New zone contains errors: $message");
    }
    return $status;
}

sub _load_modules_needed_for_chroot_copy_chown {
    require Cpanel::FileUtils::Copy;
    require Cpanel::SafetyBits::Chown;

    return;
}

sub _fetch_uri_encoded_keys {
    my ($zone) = @_;

    local $@;
    my $dnssec = eval { Cpanel::NameServer::DNSSEC::SyncKeys->new($zone) };
    return '' unless defined $dnssec;

    my $keydata = $dnssec->get_active_keydata();
    my $output  = '';
    foreach my $tag ( keys %{$keydata} ) {
        $output .= "cpdnskey$tag-" . Cpanel::Encoder::URI::uri_encode_str($zone) . "=" . Cpanel::Encoder::URI::uri_encode_str( $keydata->{$tag} ) . "&";
    }
    return $output;
}

sub _activate_dnssec_keys {
    my ( $dataref, @keys_to_process ) = @_;

    my %zonekeys;
    foreach my $zonename (@keys_to_process) {
        next if $zonename !~ m/^cpdnskey([0-9]+)-(.+)/;
        my $tag  = $1;
        my $zone = $2;

        next if !Cpanel::Validate::Domain::Tiny::validdomainname($zone);
        my %keydata;
        $keydata{$tag}{data} = $dataref->{$zonename};
        ( $keydata{$tag}{type} ) = $dataref->{$zonename} =~ /^;([CKZ]SK)/;
        $zonekeys{$zone} = $zonekeys{$zone} ? { %{ $zonekeys{$zone} }, %keydata } : {%keydata};
    }

    foreach my $zone ( keys %zonekeys ) {
        local $@;
        my $dnssec = eval { Cpanel::NameServer::DNSSEC::SyncKeys->new($zone) };
        next unless defined $dnssec;
        $dnssec->activate_keys( $zonekeys{$zone} );
    }

    return 1;
}

1;
