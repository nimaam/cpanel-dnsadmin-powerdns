package Cpanel::NameServer::Utils::BIND;

#                                      Copyright 2024 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

use strict;
use warnings;

use Cpanel::Debug              ();
use Cpanel::Config::LoadConfig ();
use Cpanel::FindBin            ();

our $VERSION = '1.2';

my $cached_namedconf;
my $cached_chrootdir;
my $cached_chrootuser;
my $cached_chrootgrp;

################################################################################
# find_namedconf
# returns location of named.conf
################################################################################
sub find_namedconf {
    if ($cached_namedconf) { return $cached_namedconf; }

    # Determine OS default dir for named.conf
    my $sysconfdir = '/etc';
    my $namedconf  = $sysconfdir . '/named.conf';

    if ( !-e $namedconf ) {
        require Cpanel::FileUtils::Link;
        Cpanel::Debug::log_warn("Attempting to locate $namedconf");
        if ( -e '/etc/namedb/named.conf' ) {
            Cpanel::FileUtils::Link::safelink( '/etc/namedb/named.conf', $namedconf );
        }
        elsif ( -e '/etc/bind/named.conf' ) {
            Cpanel::FileUtils::Link::safelink( '/etc/bind/named.conf', $namedconf );
        }
        elsif ( -e '/etc/named.conf' ) {
            Cpanel::FileUtils::Link::safelink( '/etc/named.conf', $namedconf );
        }
        elsif ( -e '/etc/named.conf.rpmsave' ) {
            Cpanel::FileUtils::Link::safelink( '/etc/named.conf.rpmsave', $namedconf );
        }
        else {
            Cpanel::Debug::log_warn('no bind configuration present');
            $namedconf = '';
        }
    }

    $cached_namedconf = $namedconf;
    return $namedconf;
}

sub checknamedconf {
    my $conffile = shift;
    my $output   = '';

    my $checkconf = Cpanel::FindBin::findbin('named-checkconf');

    if ( !length $checkconf ) {
        Cpanel::Debug::log_warn('named-checkconf not located on system. Check your Bind installation.');
        return ( 1, '' ) if wantarray;
        return 1;
    }
    else {
        require Cpanel::SafeRun::Errors;
        $output = Cpanel::SafeRun::Errors::saferunallerrors( $checkconf, $conffile ) || '';
        chomp $output;
        if ( $output ne '' ) {
            return ( 0, $output ) if wantarray;
            return 0;
        }
        else {
            return ( 1, '' ) if wantarray;
            return 1;
        }
    }
    return ( 1, '' ) if wantarray;
    return 1;
}

sub find_chrootbinddir {
    if ( defined $cached_chrootdir ) {
        if (wantarray) {
            return ( $cached_chrootdir, $cached_chrootuser, $cached_chrootgrp );
        }
        else {
            return $cached_chrootdir;
        }
    }

    my $chrootdir = '';

    my $chrootjail    = '';
    my $bindsetup     = '/etc/sysconfig/named';
    my $chrootvar     = 'ROOTDIR';
    my $chrootjailvar = '';
    my $chrootuser    = 'named';
    my $chrootgrp     = 'named';

    my $bindsetup_cfgref = Cpanel::Config::LoadConfig::loadConfig($bindsetup);
    foreach my $var ( $chrootvar, $chrootjailvar ) {
        if ( exists $bindsetup_cfgref->{$var} ) {
            $bindsetup_cfgref->{$var} =~ s/^[\"\']//;
            $bindsetup_cfgref->{$var} =~ s/[\"\']$//;
        }
    }
    $chrootdir  = $bindsetup_cfgref->{$chrootvar}     if exists $bindsetup_cfgref->{$chrootvar};
    $chrootjail = $bindsetup_cfgref->{$chrootjailvar} if exists $bindsetup_cfgref->{$chrootjailvar};
    if ($chrootjail) {
        $chrootjail =~ s/\$\{$chrootvar\}//;
        $chrootdir = $chrootdir . $chrootjail;
    }
    my %BADCHROOT = (
        '/usr'  => 1,
        '/'     => 1,
        '/var'  => 1,
        '/home' => 1,
        '/proc' => 1,
        '/dev'  => 1,
        '/bin'  => 1,
        '/sbin' => 1,
        '/tmp'  => 1,
        '/lib'  => 1,
        '/root' => 1,
        '/etc'  => 1,
    );    # Prevent really stupid things.

    $cached_chrootuser = $chrootuser;
    $cached_chrootgrp  = $chrootgrp;

    if ( exists( $BADCHROOT{$chrootdir} ) ) {
        Cpanel::Debug::log_warn("Bind chroot directory is $chrootdir, this is a horrible idea.");
        $cached_chrootdir = '';
        return '';
    }
    elsif ( $chrootdir eq '' ) {
        $cached_chrootdir = '';
        if (wantarray) { return ( '', $chrootuser, $chrootgrp ) }
        else           { return ''; }
    }
    elsif ( !-d $chrootdir ) {

        if ( -e $chrootdir ) {
            require Cpanel::FileUtils::Move;
            Cpanel::FileUtils::Move::safemv( $chrootdir, $chrootdir . '.cpbackup' );
        }
        require Cpanel::SafeDir::MK;
        require Cpanel::SafetyBits::Chown;

        Cpanel::SafeDir::MK::safemkdir($chrootdir);
        Cpanel::SafetyBits::Chown::safe_chown_guess_gid( $chrootuser, $chrootdir );
    }
    else {
        chmod( oct('0755'), $chrootdir );
    }

    $cached_chrootdir = $chrootdir;

    if (wantarray) { return ( $chrootdir, $chrootuser, $chrootgrp ) }
    else           { return $chrootdir }

}

sub named_version {
    my $named_bin = '';

    my @LOC = ( '/usr/local/sbin/named', '/usr/sbin/named', '/usr/bin/named' );
    foreach my $loc (@LOC) {
        if ( -x $loc ) {
            $named_bin = $loc;
        }
    }

    if ( $named_bin eq '' ) {
        Cpanel::Debug::log_warn('named not located on system. Check your Bind installation.');
        return { success => 0, major => undef, minor => undef, nano => undef, string => undef };
    }
    else {
        require Cpanel::SafeRun::Errors;
        my $output = Cpanel::SafeRun::Errors::saferunallerrors( $named_bin, '-v' ) || '';
        chomp $output;
        if ( $output ne '' ) {

            # BIND 9.11.36-RedHat-9.11.36-8.el8_8.1 (Extended Support Version) <id:68dbd5b>

            my ( $major, $minor, $nano );
            if ( $output =~ m/^BIND (\d+)\.(\d+)\.(\d+)/ ) {
                $major = $1;
                $minor = $2;
                $nano  = $3;
            }

            if ( !$major ) {    # could not parse
                Cpanel::Debug::log_warn("Could not determine named version");
                return { success => 0, major => undef, minor => undef, nano => undef, string => undef };
            }

            return { success => 1, major => $major, minor => $minor, nano => $nano, string => "$major.$minor.$nano" };
        }
        else {
            Cpanel::Debug::log_warn("Could not determine named version");
            return { success => 0, major => undef, minor => undef, nano => undef, string => undef };
        }
    }

    # should never reach here
    return { success => 0, major => undef, minor => undef, nano => undef, string => undef };
}

1;
