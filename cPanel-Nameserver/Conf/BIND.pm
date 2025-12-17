package Cpanel::NameServer::Conf::BIND;

#                                      Copyright 2024 WebPros International, LLC
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited.

use cPstrict;
use bytes;

use Cpanel::Debug                   ();
use Cpanel::FileUtils::Write        ();
use Cpanel::AdminBin::Serializer    ();
use Cpanel::PwCache                 ();
use Cpanel::SafeFile                ();
use Cpanel::NameServer::Utils::BIND ();
use Cpanel::CommentKiller           ();
use Cpanel::OS                      ();

our $VERSION = '2.3';

my $datastore_version = '1.7';

my %BIND_CONFIG_SINGLETON;

our $debug = Cpanel::Debug::debug_level();

# Use this constant when we know the cache is up to date
# since we already checked it in the function
our $SKIP_CACHE_CHECK = 1;

sub new {
    my $class = shift;
    my $self  = bless {}, $class;
    $self->initialize();
    return $self;
}

sub type { return 'bind'; }

sub initialize {
    my $self = shift;
    if ( exists $self->{ 'initialized_' . __PACKAGE__ } && $self->{ 'initialized_' . __PACKAGE__ } ) {
        return;
    }

    $self->{'namedconffile'} = Cpanel::NameServer::Utils::BIND::find_namedconf();
    if ( !-e $self->{'namedconffile'} ) {
        _logger()->info("Initializing $self->{'namedconffile'}");
        require Cpanel::SafeRun::Errors;
        Cpanel::SafeRun::Errors::saferunallerrors('/usr/local/cpanel/scripts/rebuilddnsconfig');
        $self->{'namedconffile'} = Cpanel::NameServer::Utils::BIND::find_namedconf();
    }

    $self->{'dirty'} = 0;

    if ( !scalar keys %BIND_CONFIG_SINGLETON ) {
        my ( $chrootdir, $user, $group ) = Cpanel::NameServer::Utils::BIND::find_chrootbinddir();
        my ( $uid, $gid ) = ( Cpanel::PwCache::getpwnam_noshadow($user) )[ 2, 3 ];

        %BIND_CONFIG_SINGLETON = (
            'user'      => $user,
            'group'     => $group,
            'uid'       => $uid,
            'gid'       => $gid,
            'chrootdir' => $chrootdir,
        );
    }

    $self->{'chrootdir'}     = $BIND_CONFIG_SINGLETON{'chrootdir'};
    $self->{'bind'}{'user'}  = $BIND_CONFIG_SINGLETON{'user'};
    $self->{'bind'}{'group'} = $BIND_CONFIG_SINGLETON{'group'};
    $self->{'bind'}{'uid'}   = $BIND_CONFIG_SINGLETON{'uid'};
    $self->{'bind'}{'gid'}   = $BIND_CONFIG_SINGLETON{'gid'};

    return ( $self->{ 'initialized_' . __PACKAGE__ } = 1 );
}

#
# Used to testing the cache -- assumes checkcache has been run
# not used under normal circumstances
#
sub validate_cache {
    my ($self) = @_;

    my $ndc_fh;
    if ( !-e $self->{'namedconffile'} ) {
        _logger()->info("Initializing $self->{'namedconffile'}");
        require Cpanel::SafeRun::Errors;
        Cpanel::SafeRun::Errors::saferunallerrors('/usr/local/cpanel/scripts/rebuilddnsconfig');
        $self->{'namedconffile'} = Cpanel::NameServer::Utils::BIND::find_namedconf();
    }
    my $ndclock = Cpanel::SafeFile::safeopen( $ndc_fh, '+<', $self->{'namedconffile'} );
    if ( !$ndclock ) {
        _logger()->warn("Could not edit $self->{'namedconffile'}");
        return;
    }
    foreach my $view ( keys %{ $self->{'config'}->{'v'} } ) {
        print "Testing $view\n";
        foreach my $pnt ( keys %{ $self->{'config'}->{'v'}->{$view} } ) {
            seek( $ndc_fh, $self->{'config'}->{'v'}->{$view}->{$pnt}, 0 );
            my $data = readline($ndc_fh);
            chomp($data);
            print "\t$pnt:$self->{'config'}->{'v'}->{$view}->{$pnt}: [$data]\n";
        }
    }
    Cpanel::SafeFile::safeclose( $ndc_fh, $ndclock );
    return 1;
}

# Private methods via scoping
my $log_debug                 = $debug ? sub { Cpanel::Debug::log_debug(@_) } : sub { };
my $memcache_for_key_is_valid = sub {
    my ( $self, $key, $file_mtime ) = @_;

    # The memory cache is only valid when it has an mtime at least one second newer than
    # named.conf.  See Case 39520 for detailed examples of why this is required.
    $self->{$key} //= 0;    # Prevent unint var in debug prints
    if ( $self->{$key} > $file_mtime ) {
        $log_debug->("$$ [memory cache for '$key' is valid]");
        return 1;
    }
    $log_debug->("$$ ['$key' memory cache too old :: $self->{$key} (memory) < $self->{'namedconffile'} [$file_mtime] ]");
};

sub check_zonedir_cache {
    my ( $self, $fh ) = @_;

    my $named_conf_filesys_mtime = ( stat( $self->{'namedconffile'} ) )[9];

    return if $self->$memcache_for_key_is_valid( 'zonedir_configmtime', $named_conf_filesys_mtime );

    my $named_conf_zonedir_cache_filesys_mtime = ( stat( $self->{'namedconffile'} . '.zonedir.cache' ) )[9];

    if ( $named_conf_zonedir_cache_filesys_mtime && $named_conf_zonedir_cache_filesys_mtime >= $named_conf_filesys_mtime ) {
        $log_debug->("$$ [loading zonedir cache file]");
        $log_debug->("$$ [cache file ok ( $self->{'namedconffile'}.zonedir.cache [$named_conf_zonedir_cache_filesys_mtime] >= $self->{'namedconffile'} [$named_conf_filesys_mtime] ) ]");
        my $zonedircache;

        # The memory cache validity time is the instant that the storable cache is opened
        # so it must be stored first
        my $time_right_before_zonedir_cache_open = time();
        if ( open( my $named_cache_fh, '<', $self->{'namedconffile'} . '.zonedir.cache' ) ) {
            eval { $zonedircache = Cpanel::AdminBin::Serializer::LoadFile($named_cache_fh); };
            close($named_cache_fh);
        }
        if ( exists $zonedircache->{'zonedir'} ) {
            $self->{'zonedir_configmtime'} = $time_right_before_zonedir_cache_open;
            $self->{'config'}->{'zonedir'} = $zonedircache->{'zonedir'};
            mkdir( $self->{'config'}->{'zonedir'} . '/cache', 0700 ) if ( !-e $self->{'config'}->{'zonedir'} . '/cache' );
            return;
        }
    }
    else {
        $log_debug->("$$ [cache file too old ( $self->{'namedconffile'}.zonedir.cache [$named_conf_zonedir_cache_filesys_mtime] < $self->{'namedconffile'} [$named_conf_filesys_mtime] ) ]");
    }

    return $self->checkcache($fh);
}

sub _check_for_required_zones_in_cache {
    my ( $self, $zone_ref ) = @_;
    if ( !$zone_ref ) { return 0; }

    foreach my $zone ( keys %$zone_ref ) {
        if (
            exists $self->{'config'}->{'z'}->{$zone}
            && (
                !defined $self->{'config'}->{'z'}->{$zone}    #not set to undef
                || !exists $self->{'config'}->{'z'}->{$zone}->{'v'}
            )
        ) {
            $log_debug->("$$ [ config -> z -> $zone -> v cache miss ]");
            return 0;
        }
    }

    $log_debug->("$$ [using memory cache]");
    return 1;
}

sub checkcache {    ## no critic qw(Subroutines::ProhibitExcessComplexity)
    my ( $self, $fh, $zone_ref ) = @_;

    my $closefh                  = 0;
    my $named_conf_filesys_mtime = ( stat( $self->{'namedconffile'} ) )[9];

    if ( $debug && $zone_ref ) {
        foreach my $zone ( keys %$zone_ref ) {
            $log_debug->("$$ [required zone] $zone");
        }
    }

    # The memory cache is only valid when it has an mtime at least one second newer than
    # named.conf.  See Case 39520 for detailed examples of why this is required.
    if ( $self->$memcache_for_key_is_valid( 'configmtime', $named_conf_filesys_mtime ) ) {
        return if ( $self->_check_for_required_zones_in_cache($zone_ref) );
        $log_debug->("$$ [memory cache does not contain all required zones]");
    }

    my $named_conf_cache_filesys_mtime = ( stat( $self->{'namedconffile'} . '.cache' ) )[9] // 0;

    if ( $named_conf_cache_filesys_mtime && $named_conf_cache_filesys_mtime >= $named_conf_filesys_mtime ) {
        $log_debug->("$$ [loading cache file ( $self->{'namedconffile'}.cache [$named_conf_cache_filesys_mtime] >= $self->{'namedconffile'} [$named_conf_filesys_mtime] ) ]");

        # The memory cache validity time is the instant that the storable cache is opened
        # so it must be stored first
        my $time_right_before_cache_open = time();

        if ( open( my $named_cache_fh, '<', $self->{'namedconffile'} . '.cache' ) ) {
            eval { $self->{'config'} = Cpanel::AdminBin::Serializer::LoadFile($named_cache_fh); };
            close($named_cache_fh);
            $zone_ref = $self->{'config'};    # Set zone_ref to new
        }
        if ( $self->{'config'} && ref $self->{'config'} eq 'HASH' && $self->{'config'}->{'version'} eq $datastore_version ) {

            if ( $self->_check_for_required_zones_in_cache($zone_ref) ) {

                # We set the (zonedir)?configmtime because
                # we are actually going to use the cache because we have seen it as valid
                # otherwise we will fall through and do a full load below
                $self->{'zonedir_configmtime'} = $self->{'configmtime'} = $time_right_before_cache_open;
                return;
            }
            else {
                $log_debug->("$$ [disk cache is missing required zones]");
            }
        }
    }
    else {
        $log_debug->("$$ [cache file too old ( $self->{'namedconffile'}.cache [$named_conf_cache_filesys_mtime] < $self->{'namedconffile'} [$named_conf_filesys_mtime] ) ]");
    }

    $log_debug->("$$ [doing full read]");
    my $ndclock;
    if ( !$fh ) {
        $ndclock = Cpanel::SafeFile::safeopen( $fh, '<', $self->{'namedconffile'} );
        if ( !$ndclock ) {
            _logger()->warn("Could not read from $self->{'namedconffile'}");
            return;
        }
        $closefh = 1;
    }
    my $view = 'full';
    my $zone;

    my $inview         = 0;
    my $inoptions      = 0;
    my $numbrace       = 0;
    my $inzone         = 0;
    my $zonebracestart = 0;
    $self->{'config'} = { 'version' => $datastore_version };
    my $commentkiller = Cpanel::CommentKiller->new;
    my $parsed;

    while ( readline $fh ) {
        next if !length || !tr{ \t\f\n}{}c;

        # If it's not in a multiline comment and doesn't contain *, #, or // it cannot be a comment
        $parsed = ( !$commentkiller->{'in_c_comment'} && ( !tr[*#/][] || ( !tr[*#][] && index( $_, '//' ) == -1 ) ) ) ? $_ : $commentkiller->parse($_);
        next if !length $parsed;

        if ( $inzone == 1 ) {
            if ( $parsed =~ tr/{}// ) {

                #StringFunc::get_curly_brace_count($parsed);
                #Only check to see if we left the zone if
                if ( ( $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) ) ) <= $zonebracestart ) {
                    $inzone = 0;
                    if ( $zone_ref->{$zone} ) {
                        ${ $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view} }[1] = int tell($fh);
                    }
                }
            }
        }
        else {

            # no elsif since most of the time we will be in zone

            if ($inview) {
                if ( $parsed =~ m/^\s*zone\s+\"(\S+)\"/i ) {
                    ( $inzone, $zonebracestart, $zone ) = ( 1, $numbrace, $1 );
                    if ( $zone_ref->{$zone} ) {
                        ${ $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view} }[0] = tell($fh) - length($_);    # 0 = start
                    }
                    else {
                        $self->{'config'}->{'z'}->{$zone} = undef;
                    }

                    #StringFunc::get_curly_brace_count($parsed);
                    if ( ( $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) ) ) == $zonebracestart ) {
                        if ( $zone_ref->{$zone} ) {
                            ${ $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view} }[1] = int tell($fh);    # 1 = end
                        }
                        $inzone = 0;
                    }
                }
                else {
                    $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) );    #StringFunc::get_curly_brace_count($parsed);
                }
                if ( $numbrace == 0 ) {
                    $self->{'config'}->{'v'}->{$view}->{'e'}  = int tell($fh);
                    $self->{'config'}->{'v'}->{$view}->{'le'} = ( ( int tell($fh) ) - length($_) );
                    $log_debug->( "$$ PARSE -- LINE END VIEW: [$view] [" . $self->{'config'}->{'v'}->{$view}->{'le'} . "]" );
                    $view   = 'full';
                    $inview = 0;
                }
            }
            elsif ( $parsed =~ m/^\s*zone\s+\"(\S+)\"/i ) {
                ( $inzone, $zonebracestart, $zone ) = ( 1, $numbrace, $1 );
                $log_debug->("$$ [PARSE] Entering zone: $zone");
                if ( $zone_ref->{$zone} ) {
                    ${ $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view} }[0] = tell($fh) - length($_);    # 0 = start
                }
                else {
                    $self->{'config'}->{'z'}->{$zone} = undef;
                }
                if ( ( $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) ) ) == $zonebracestart ) {
                    if ( $zone_ref->{$zone} ) {
                        ${ $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view} }[1] = int tell($fh);    # 1 = end
                    }
                    $inzone = 0;
                }
            }
            elsif ( !$inview ) {
                if ( $parsed =~ m/^\s*view\s*\"(internal|external)/ ) {
                    $view   = $1;
                    $inview = 1;
                    $log_debug->("$$ [PARSE] Entering view: $view");

                    my $prebrace = $numbrace;
                    $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) );    #StringFunc::get_curly_brace_count($parsed);
                    while ( $numbrace == $prebrace && !eof($fh) ) {
                        $_      = readline $fh || last;
                        $parsed = $commentkiller->parse($_);
                        $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) );    #StringFunc::get_curly_brace_count($parsed);
                    }
                    $self->{'config'}->{'v'}->{$view}->{'s'}  = tell($fh) - length($_);
                    $self->{'config'}->{'v'}->{$view}->{'ls'} = tell($fh);

                }
                elsif ( $parsed =~ m/^\s*options/i ) {
                    $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) );    #StringFunc::get_curly_brace_count($parsed);
                    if ( $parsed =~ m/(?:^|\s)directory\s+["']?([^"']+)/ ) {
                        $self->{'config'}->{'zonedir'} = $1;
                    }
                    else {
                        $inoptions = 1;
                    }
                }
                elsif ($inoptions) {
                    $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) );    #StringFunc::get_curly_brace_count($parsed);
                    if ( $parsed =~ m/(?:^|\s)directory\s+["']?([^"']+)/ ) {
                        $self->{'config'}->{'zonedir'} = $1;
                    }
                    if ( $numbrace == 0 ) {
                        $inoptions = 0;
                    }
                }
                else {
                    $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) );    #StringFunc::get_curly_brace_count($parsed);
                }
            }
            else {
                $numbrace += ( ( $parsed =~ tr/{// ) - ( $parsed =~ tr/}// ) );        #StringFunc::get_curly_brace_count($parsed);
            }
        }
    }

    if ( !$self->{'config'}->{'zonedir'} || $self->{'config'}->{'zonedir'} eq '/' ) {
        $self->{'config'}->{'zonedir'} = Cpanel::OS::dns_named_basedir();
    }

    mkdir( $self->{'config'}->{'zonedir'} . '/cache', 0700 ) if ( !-e $self->{'config'}->{'zonedir'} . '/cache' );

    if ($closefh) {

        # The cache MUST be written now before we give up the lock to ensure sync
        # This also updates the memory times to the current second
        $self->write_zonedir_cache();
        $self->writecache();
        Cpanel::SafeFile::safeclose( $fh, $ndclock );
        $self->{'dirty'} = 0;
    }
    else {

        # Update memory cache validity to the last possible second
        $self->{'zonedir_configmtime'} = $self->{'configmtime'} = time();
        $self->{'dirty'}               = 1;                                 # this must get cleaned when the function that called us with the open fh finishes
    }
    return;
}

sub writecache {
    my $self = shift;
    $self->{'configmtime'} = time();
    $log_debug->("$$ [writing cache]");
    Cpanel::FileUtils::Write::overwrite( $self->{'namedconffile'} . '.cache', Cpanel::AdminBin::Serializer::Dump( $self->{'config'} ), 0600 );
    return 1;
}

sub write_zonedir_cache {
    my $self = shift;
    $self->{'zonedir_configmtime'} = time();
    $log_debug->("$$ [writing zonedir cache]");
    Cpanel::FileUtils::Write::overwrite( $self->{'namedconffile'} . '.zonedir.cache', Cpanel::AdminBin::Serializer::Dump( { 'zonedir' => $self->{'config'}->{'zonedir'}, 'zonedir_configmtime' => $self->{'zonedir_configmtime'} } ), 0600 );
    return 1;
}

sub removezones {
    my ( $self, @zones ) = @_;
    $log_debug->( "$$ ---- removezones --- " . join( ' ', @zones ) . " ---" );
    $log_debug->( "$$ named.conf mtime " . ( stat( $self->{'namedconffile'} ) )[9] );
    $log_debug->( "$$ memory mtime " . ( $self->{'configmtime'} // '' ) );

    my $ndc_fh;
    if ( !-e $self->{'namedconffile'} ) {
        _logger()->warn("Could not find $self->{'namedconffile'}");
        return;    # removing zones from a nonexistent named.conf .. no reason to continue..
    }
    my $ndclock = Cpanel::SafeFile::safeopen( $ndc_fh, '+<', $self->{'namedconffile'} );
    if ( !$ndclock ) {
        _logger()->warn("Could not edit $self->{'namedconffile'}");
        return;
    }
    $self->checkcache( $ndc_fh, { map { $_ => 1 } @zones } );

    my @removed_zones   = ();
    my %removal_offsets = ();

    my @viewlist;
    if ( $self->viewcount(1) > 0 ) {
        my %views = ();
        foreach my $zone (@zones) {
            next if !exists $self->{'config'}->{'z'}->{$zone};    # prevent auto vivify
            foreach my $view ( keys %{ $self->{'config'}->{'z'}->{$zone}->{'v'} } ) {
                $views{$view} = 1;
            }
        }
        @viewlist = keys %views;
    }
    else {
        @viewlist = ('full');
    }

    foreach my $zone (@zones) {
        if ( !exists $self->{'config'}->{'z'}->{$zone} ) {
            _logger()->warn("$zone does not exist in named.conf") unless $ENV{'TAP_VERSION'};    # Don't warn in unit tests.
        }
        elsif ( !( scalar keys %{ $self->{'config'}->{'z'}->{$zone}->{'v'} } ) ) {
            push @removed_zones, $zone;
            delete $self->{'config'}->{'z'}->{$zone};
        }
        else {
            foreach my $view (@viewlist) {
                next if ( !defined $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view} );
                my $start = ${ $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view} }[0];    # 0 = start
                my $end   = ${ $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view} }[1];    # 1 = end
                $removal_offsets{$start} = $end;

                $log_debug->("$$ [zone] $zone [remove] view = $view -- start = $start -- end - $end");
                delete $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view};
            }
            push @removed_zones, $zone;

            delete $self->{'config'}->{'z'}->{$zone};
        }
    }

    if ( scalar keys %removal_offsets ) {
        local $/;
        seek $ndc_fh, 0, 0;
        my $file          = readline $ndc_fh;
        my $ending_offset = 0;
        seek $ndc_fh, 0, 0;
        my $removed_offset = 0;

        foreach my $starting_offset ( sort { $a <=> $b } keys %removal_offsets ) {

            # Print from the end of the last block to the beginning of the current block
            if ( $starting_offset > $ending_offset ) {
                print $ndc_fh substr( $file, $ending_offset, ( $starting_offset - $ending_offset ) );
            }
            my $removal_length = $removal_offsets{$starting_offset} - $starting_offset;
            $self->renumber_map( $starting_offset - $removed_offset, $removal_length, 1 );
            $removed_offset += $removal_length;
            $ending_offset = $removal_offsets{$starting_offset};
        }

        print $ndc_fh substr( $file, $ending_offset );
        truncate( $ndc_fh, tell($ndc_fh) );
    }
    elsif ( !( scalar @removed_zones ) ) {
        Cpanel::SafeFile::safeclose( $ndc_fh, $ndclock );
        return;
    }

    $self->write_zonedir_cache();
    $self->writecache();

    Cpanel::SafeFile::safeclose( $ndc_fh, $ndclock );
    $self->{'dirty'} = 0;    #write cache happened!
    return @removed_zones;
}

sub removezone {
    my ( $self, $zone ) = @_;
    return scalar $self->removezones($zone) ? 1 : 0;
}

sub addzones {
    my ( $self, @zones ) = @_;
    $log_debug->( "$$ ---- addzones --- " . join( ' ', @zones ) . " ---" );

    if ( !-e $self->{'namedconffile'} ) {
        _logger()->info("Initializing $self->{'namedconffile'}");
        require Cpanel::SafeRun::Errors;
        Cpanel::SafeRun::Errors::saferunallerrors('/usr/local/cpanel/scripts/rebuilddnsconfig');
        $self->{'namedconffile'} = Cpanel::NameServer::Utils::BIND::find_namedconf();
    }

    my $ndc_fh;
    my $ndclock = Cpanel::SafeFile::safeopen( $ndc_fh, '+<', $self->{'namedconffile'} );
    if ( !$ndclock ) {
        _logger()->warn("Could not edit $self->{'namedconffile'}");
        return;
    }
    $self->checkcache($ndc_fh);
    my %zone_offsets   = ();
    my @zoneconf       = ();
    my $running_length = 0;
    foreach my $newzone (@zones) {
        if ( exists $self->{'config'}->{'z'}->{$newzone} ) {
            _logger()->info("$newzone already exist in named.conf");
            next;
        }
        next if ( exists $zone_offsets{$newzone} );    # Dupes passed in

        $zone_offsets{$newzone}{'s'} = $running_length;     # Starting point
        my $zoneline = "\nzone \"$newzone\" {\n\ttype master;\n\tfile \"" . $self->{'config'}->{'zonedir'} . "/$newzone.db\";\n};\n\n";
        $zone_offsets{$newzone}{'l'} = length($zoneline);
        $running_length += $zone_offsets{$newzone}{'l'};    # length of this zone's entry
        push @zoneconf, $zoneline;
    }
    unless ( scalar keys %zone_offsets ) {
        _logger()->info("No valid zones supplied to addzones");
        Cpanel::SafeFile::safeclose( $ndc_fh, $ndclock );
        return;
    }

    my $file;
    my $modded = 0;
    if ( $self->viewcount(1) > 0 ) {
        foreach my $view ( keys %{ $self->{'config'}->{'v'} } ) {
            $modded = 1;
            my $start = $self->{'config'}->{'v'}->{$view}->{'le'};
            {
                local $/;
                seek( $ndc_fh, $start, 0 );
                $file = readline $ndc_fh;
                seek( $ndc_fh, $start, 0 );
                truncate( $ndc_fh, tell($ndc_fh) );
                print {$ndc_fh} join( '', @zoneconf );
                print {$ndc_fh} $file;
                truncate( $ndc_fh, tell($ndc_fh) );
            }
            $self->renumber_map( $start, $running_length, 0 );
            foreach my $newzone ( keys %zone_offsets ) {
                ${ $self->{'config'}->{'z'}->{$newzone}->{'v'}->{$view} }[0] = $start + $zone_offsets{$newzone}{'s'};                                   #0 = start
                ${ $self->{'config'}->{'z'}->{$newzone}->{'v'}->{$view} }[1] = $start + $zone_offsets{$newzone}{'s'} + $zone_offsets{$newzone}{'l'};    # 1 = end
            }
        }
    }
    else {
        my $view = 'full';
        $modded = 1;
        seek( $ndc_fh, 0, 2 );
        my $start = tell($ndc_fh);
        foreach my $newzone ( keys %zone_offsets ) {
            ${ $self->{'config'}->{'z'}->{$newzone}->{'v'}->{$view} }[0] = $start + $zone_offsets{$newzone}{'s'};                                   #0 = start
            ${ $self->{'config'}->{'z'}->{$newzone}->{'v'}->{$view} }[1] = $start + $zone_offsets{$newzone}{'s'} + $zone_offsets{$newzone}{'l'};    # 1 = end
        }
        print {$ndc_fh} join( '', @zoneconf );
        truncate( $ndc_fh, tell($ndc_fh) );
    }

    if ( !$modded ) {
        Cpanel::SafeFile::safeclose( $ndc_fh, $ndclock );
        return;
    }

    $self->write_zonedir_cache();
    $self->writecache();
    Cpanel::SafeFile::safeclose( $ndc_fh, $ndclock );
    $self->{'dirty'} = 0;    #write cache happened!
    return keys %zone_offsets;
}

sub addzone {
    my ( $self, $zone ) = @_;

    return scalar $self->addzones($zone) ? 1 : 0;
}

sub renumber_map {
    my ( $self, $start, $splice_amount, $remove ) = @_;
    die if !defined $start;

    my $offset_amount = ( $remove ? $splice_amount : ( -1 * $splice_amount ) );
    $log_debug->( "$$ [renumbering from " . ( $remove ? 'removing from' : 'adding to' ) . "]" );
    foreach my $view ( keys %{ $self->{'config'}->{'v'} } ) {
        $log_debug->( "$$ [[ View ]] $view  -- Start" . $self->{'config'}->{'v'}->{$view}->{'s'} );
        $log_debug->( "$$ [[ View ]] $view  -- End" . $self->{'config'}->{'v'}->{$view}->{'e'} );
        $log_debug->("$$ [[ Add Start]] $start");

        my @pnts;
        if ( $self->{'config'}->{'v'}->{$view}->{'s'} >= $start ) {
            push @pnts, 's', 'ls';
        }
        if ( $self->{'config'}->{'v'}->{$view}->{'e'} >= $start ) {
            push @pnts, 'e', 'le';
        }
        foreach my $pnt (@pnts) {
            $self->{'config'}->{'v'}->{$view}->{$pnt} -= $offset_amount;
        }
    }
    my $zone_ref = $self->{'config'}->{'z'};
    foreach my $zone ( grep { defined $zone_ref->{$_} } keys %$zone_ref ) {    # defined prevents auto vivify
        foreach ( grep { $_->[0] >= $start } values %{ $zone_ref->{$zone}->{'v'} } ) {
            $_->[0] -= $offset_amount;                                         # start;
            $_->[1] -= $offset_amount;                                         # end;
        }
    }
    if ($debug) {
        foreach my $view ( keys %{ $self->{'config'}->{'v'} } ) {
            $log_debug->( "$$ [[ ViewAfter ]] $view  -- Start" . $self->{'config'}->{'v'}->{$view}->{'s'} );
            $log_debug->( "$$ [[ ViewAfter ]] $view  -- End" . $self->{'config'}->{'v'}->{$view}->{'e'} );
        }
    }
    return;
}

sub getviews {
    my $self             = shift;
    my $skip_cache_check = shift;
    if ( !$skip_cache_check ) {
        $self->checkcache();
    }
    return keys %{ $self->{'config'}->{'v'} };
}

sub viewcount {
    my $self             = shift;
    my $skip_cache_check = shift;
    if ( !$skip_cache_check ) {
        $self->checkcache();
    }
    $log_debug->( "$$ [Number of views: " . ( scalar keys %{ $self->{'config'}->{'v'} } ) . "]\n" );
    return ( scalar keys %{ $self->{'config'}->{'v'} } );
}

sub viewhaszonesfilter {
    my $self             = shift;
    my $view             = shift || return 0;
    my $zones_ar         = shift || return 0;
    my $skip_cache_check = shift;

    my %req_zones_map = map { $_ => 1 } @$zones_ar;
    if ( !$skip_cache_check ) {
        $self->checkcache( undef, \%req_zones_map );
    }

    my @found_zones = ();
    foreach my $zone (@$zones_ar) {
        push @found_zones, $zone if ( exists $self->{'config'}->{'z'}->{$zone} && defined $self->{'config'}->{'z'}->{$zone}->{'v'}->{$view} );
    }
    return wantarray ? @found_zones : \@found_zones;
}

sub listviews {
    my $self = shift;
    $self->checkcache();
    foreach my $view ( sort keys %{ $self->{'config'}->{'v'} } ) {
        print $view . "\n";
    }
}

sub fetchzones {
    my $self = shift;
    $self->checkcache();
    my @zones = sort keys %{ $self->{'config'}->{'z'} };
    return \@zones;
}

sub haszone {
    my $self             = shift;
    my $zone             = shift;
    my $skip_check_cache = shift;
    if ( !$skip_check_cache ) { $self->checkcache(); }
    if ( exists $self->{'config'}->{'z'}->{$zone} ) {
        if ( defined $self->{'config'}->{'z'}->{$zone}->{'v'} && !( scalar keys %{ $self->{'config'}->{'z'}->{$zone}->{'v'} } ) ) {
            _logger()->warn("named.conf cache may be corrupt");
        }
        return 1;
    }
    return 0;
}

sub listzones {
    my $self = shift;
    $self->checkcache();
    foreach my $zone ( sort keys %{ $self->{'config'}->{'z'} } ) {
        print $zone . "\n";
    }
}

sub zonedir {
    my $self = shift;
    $self->check_zonedir_cache();
    return $self->{'config'}->{'zonedir'};
}

sub makeclean {
    my $self = shift;
    return if !$self->{'dirty'};
    if ( !-e $self->{'namedconffile'} ) {
        _logger()->info("Initializing $self->{'namedconffile'}");
        require Cpanel::SafeRun::Errors;
        Cpanel::SafeRun::Errors::saferunallerrors('/usr/local/cpanel/scripts/rebuilddnsconfig');
        $self->{'namedconffile'} = Cpanel::NameServer::Utils::BIND::find_namedconf();
    }
    else {

        # This should never happen as the cache is should always be written
        # when checkcache is called and it is out of date
        _logger()->invalid("named.conf cache was unexpectedly dirty while running $0");
    }
    my $ndc_fh;
    my $ndclock = Cpanel::SafeFile::safeopen( $ndc_fh, '+<', $self->{'namedconffile'} );
    if ( !$ndclock ) {
        _logger()->warn("Could not edit $self->{'namedconffile'}");
        return;
    }
    $self->checkcache($ndc_fh);
    $self->write_zonedir_cache();
    $self->writecache();
    Cpanel::SafeFile::safeclose( $ndc_fh, $ndclock );

    $self->{'dirty'} = 0;
    return 1;
}

sub finish {
    my $self = shift;
    return $self->makeclean();
}

# Not implimented for named.conf, only nsd.conf
sub rebuild_conf {
    _logger()->info('rebuild_conf not implemented for Bind');
    return;
}

my $_logger;

sub _logger {
    require Cpanel::Logger;
    return $_logger ||= Cpanel::Logger->new();
}

sub DESTROY {
    my $self = shift;
    if ( $self->{'dirty'} ) {
        _logger()->warn( "Destruction of " . __PACKAGE__ . " object without cleanup: cache not updated, next load will be slow" );

        # doing makclean could be very bad durning global destruction since Storable might crash.
        # $self->makeclean();
    }
    return;
}

1;
