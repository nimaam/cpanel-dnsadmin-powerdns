package Cpanel::NameServer::DNSSEC::Cache;

# cpanel - Cpanel/NameServer/DNSSEC/Cache.pm       Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use 5.010;

use Cpanel::FileUtils::TouchFile         ();
use Cpanel::Validate::FilesystemNodeName ();

=head1 NAME

C<Cpanel::NameServer::DNSSEC::Cache>

=head1 DESCRIPTION

Slap a bunch of touchfiles in /var/cpanel/dnssec_cache to know who's naughty and nice because pdnsutil list-secure-zones is slow, slow, slow (merry christmas!)

=cut

our $cachedir = '/var/cpanel/dnssec_cache';

=head1 SUBROUTINES

=head2 has_dnssec(@zones)

Filters provided zone(s) for those with a key installed on the local pdns server last we checked.

=cut

sub has_dnssec {
    my (@zones) = @_;
    state $zones_with_keys = { map { $_ => 1 } ( _get_zones_wkeys() ) };
    return grep { $zones_with_keys->{$_} } @zones;
}

sub _get_zones_wkeys {
    my @incache;
    local $!;
    opendir( my $dir_fh, $cachedir ) or do {
        warn "Failed to open DNSSEC cache directory $cachedir: $!" if !$!{'ENOENT'};
        return @incache;
    };
    foreach my $zone ( readdir($dir_fh) ) {
        next if $zone =~ /^\./;
        push( @incache, $zone );
    }
    closedir($dir_fh);

    return @incache;
}

=head2 rebuild_cache()

Evicts stale domains from the cache, and add new ones to it.
Returns true in the event any changes to cache state were made.

=cut

sub rebuild_cache {

    _ensure_cachedir();

    require Cpanel::NameServer::Conf::PowerDNS;
    my $pdns_conf      = Cpanel::NameServer::Conf::PowerDNS->new();
    my $dnssec_domains = $pdns_conf->fetch_domains_with_dnssec();

    my @incache = _get_zones_wkeys();

    #Either you have broken zones killing pdnsutil or no secure zones,
    #so, we should only proceed if we need to mash what's there
    return 0 unless @$dnssec_domains || @incache;

    #Prevent double grep below
    my %fresh = map { $_ => 1 } @{$dnssec_domains};

    my %stale = map { $_ => 1 } @incache;

    disable($_) for grep { !$fresh{$_} } @incache;
    enable($_)  for grep { !$stale{$_} } @{$dnssec_domains};

    return 1;
}

=head2 enable($zone)

Insert zones from the cache.

Returns true/false as to the operation success, and will also warn in the event of failure.

=head2 disable($zone)

Evict zones from the cache.

Returns true/false as to the operation success, and will also warn in the event of failure.

=cut

sub enable {
    my ($zone) = @_;
    return 0 unless $zone;
    return 0 unless Cpanel::Validate::FilesystemNodeName::is_valid($zone);
    _ensure_cachedir();
    return Cpanel::FileUtils::TouchFile::touchfile("$cachedir/$zone");
}

sub disable {
    my ($zone) = @_;
    return 0 unless $zone;
    return 0 unless Cpanel::Validate::FilesystemNodeName::is_valid($zone);
    my $result = unlink "$cachedir/$zone";
    warn "Could not evict $zone from $cachedir cache: $!" if !$result && !$!{'ENOENT'};
    return $result;
}

#################################################

sub _ensure_cachedir {
    require Cpanel::SafeDir::MK;
    Cpanel::SafeDir::MK::safemkdir( $cachedir, 0700 );
    return;
}

1;
