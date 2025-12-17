package Cpanel::NameServer::Setup::Remote::cPanel;

# cpanel - Cpanel/NameServer/Setup/Remote/cPanel.pm
#                                                  Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

use Cpanel::DIp::MainIP            ();
use Cpanel::NAT::Object            ();
use Cpanel::PwCache                ();
use Cpanel::FileUtils::Copy        ();
use cPanel::PublicAPI::WHM::API    ();
use cPanel::PublicAPI::WHM::DNS    ();
use cPanel::PublicAPI::WHM::Legacy ();
use Cpanel::Ips::Fetch             ();
use Whostmgr::ACLS                 ();
use Cpanel::Version::Full          ();
use Cpanel::AccessIds::LoadFile    ();
use Socket                         ();

Whostmgr::ACLS::init_acls();

sub setup {
    my ( $self, %OPTS ) = @_;
    if ( !Whostmgr::ACLS::checkacl('clustering') ) {
        return 0, 'User does not have the clustering ACL enabled.';
    }

    return 0, 'No user given'      if !defined $OPTS{'user'};
    return 0, 'No API token given' if !defined $OPTS{'pass'};
    return 0, 'No host given'      if !defined $OPTS{'pass'} && !defined $OPTS{'accesshash'};

    # Validate debug parameter.
    # This is a boolean.
    # We do not care, nor want, the passed value, just its truthyness.

    my $debug = $OPTS{'debug'} ? 1 : 0;

    # Validate host paramenter.

    my $clustermaster = $OPTS{'host'};
    $clustermaster =~ s/\///g;
    $clustermaster =~ s/\.\.//g;
    $clustermaster =~ tr/\r\n\f\0//d;
    $clustermaster =~ s/^\s+//g;
    $clustermaster =~ s/\s+$//g;
    my $hostname = $clustermaster;

    my $inetaddr;
    if ( $clustermaster !~ /^\d+\.\d+\.\d+\.\d+$/ ) {
        if ( $inetaddr = gethostbyname($clustermaster) ) {
            $clustermaster = Socket::inet_ntoa($inetaddr);
        }
        else {
            return 0, "DNS Lookup Failed for $clustermaster";
        }
    }

    my $dnsrole = $OPTS{dnsrole};
    return 0, "Invalid dns role ($dnsrole) chosen" unless grep { $_ eq $dnsrole } qw{write-only sync standalone};

    # Validate user paramenter.

    my $user = $OPTS{'user'};
    $user =~ tr/\r\n\f\0//d;
    $user =~ s/^\s+//g;
    $user =~ s/\s+$//g;
    return 0, 'Invalid user given' if !$user;

    # Validate pass paramenter.

    my $pass = $OPTS{'pass'};
    $pass =~ tr/\r\n\f\0//d;
    $pass =~ s/^\s*\-+BEGIN\s+WHM\s+ACCESS\s+KEY\-+//g;
    $pass =~ s/\-+END\s+WHM\s+ACCESS\s+KEY\-+\s*$//g;
    $pass =~ s/^\s+//g;
    $pass =~ s/\s+$//g;
    return 0, 'Invalid API token given' if !$pass;

    my $whm = cPanel::PublicAPI->new(
        'host'            => $clustermaster,
        'user'            => $user,
        'accesshash'      => $pass,
        'usessl'          => 1,
        'ssl_verify_mode' => 0,
    );

    my $version = '10.0.0';
    my $api_result;
    $OPTS{'recurse'} //= '0';
    if ( $OPTS{'recurse'} ne '0' ) {
        $api_result = $whm->api_showversion();
        $version    = $api_result->{'version'};    #we cannot ask for the version if the recurse=0 form flag is passed or we loop, but the call is left here for future refactoring
    }

    if ( ( $whm->{'error'} && $whm->{'error'} ne '' ) || !defined $version ) {
        my $error = $whm->{'error'} || $api_result->{'statusmsg'};
        if ( $error =~ /401/ ) {
            return 0, "The remote server did not accept the authentication information. Please verify the token and username and try again. The exact message was $error. For more information check /usr/local/cpanel/logs/login_log on the remote server.";
        }
        else {
            return 0, "There was an error while processing your request: cPanel::PublicAPI returned [$error]";
        }
    }
    elsif ( grep { $_ eq $clustermaster } Cpanel::Ips::Fetch::fetchipslist() ) {
        return 0, "The specified IP address would create a cyclic trust relationship: $clustermaster";
    }

    if ( exists $OPTS{'recurse'} && $OPTS{'recurse'} ne '0' ) {
        my $remote_hostname = $whm->showhostname();
        if ( $remote_hostname =~ /[\r\n\0]/ ) {
            return 0, "The remote host returned an invalid hostname: [$remote_hostname]";
        }
        else {
            $hostname = $remote_hostname;
        }
    }

    # Check version
    my ( $majorv, $minorv, $rev ) = split( /\./, $version );
    if ( $majorv < 6 ) {
        return 0, "This operation requires the remote server to be running WHM 6.0 or later. The server reported version $version";
    }

    return $self->_setup(
        whm           => $whm,
        user          => $user,
        pass          => $pass,
        hostname      => $hostname,
        version       => $version,
        clustermaster => $clustermaster,
        dnsrole       => $dnsrole,
        debug         => $debug,
        recurse       => $OPTS{'recurse'},
        synczones     => $OPTS{'synczones'},
    );
}

sub _safe_remote_user {
    my $safe_remote_user = $ENV{'REMOTE_USER'};
    return $safe_remote_user =~ s/\///gr;
}

sub _setup {
    my ( $self, %options ) = @_;
    my ( $whm, $user, $pass, $hostname, $version, $clustermaster, $debug, $dnsrole ) = @options{qw/whm user pass hostname version clustermaster debug dnsrole/};

    my $safe_remote_user = $self->_safe_remote_user();

    #Actually get the local IP, since the remote script expects this anyways
    my $cpIP         = Cpanel::DIp::MainIP::getmainserverip();
    my $NAT_obj      = Cpanel::NAT::Object->new();
    my $NAT_local_ip = $NAT_obj->get_local_ip($cpIP);

    my $selfversion = Cpanel::Version::Full::getversion();
    my $homedir     = Cpanel::PwCache::gethomedir($safe_remote_user);
    my $success_msg = '';
    my $notices     = '';

    mkdir '/var/cpanel/cluster',                                  0700 if !-e '/var/cpanel/cluster';
    mkdir '/var/cpanel/cluster/' . $safe_remote_user,             0700 if !-e '/var/cpanel/cluster/' . $safe_remote_user;
    mkdir '/var/cpanel/cluster/' . $safe_remote_user . '/config', 0700 if !-e '/var/cpanel/cluster/' . $safe_remote_user . '/config';

    if ( open my $config_fh, '>', '/var/cpanel/cluster/' . $safe_remote_user . '/config/' . $clustermaster ) {
        chmod 0600, '/var/cpanel/cluster/' . $safe_remote_user . '/config/' . $clustermaster
          or warn "Failed to secure permissions on cluster configuration: $!";
        print {$config_fh} "#version 2.0\nuser=$user\nhost=$hostname\npass=$pass\nmodule=cPanel\ndebug=$debug\n";
        close $config_fh;
        $success_msg .= "The Trust Relationship has been established.\n";
        $success_msg .= "The remote server, $hostname, is running WHM version: $version\n";
    }
    else {
        warn "Could not write DNS trust configuration file: $!";
        return 0, "The trust relationship could not be established, please examine /usr/local/cpanel/logs/error_log for more information.";
    }

    # case 48931
    if ( !-e '/var/cpanel/cluster/root/config/' . $clustermaster && Whostmgr::ACLS::hasroot() ) {
        Cpanel::FileUtils::Copy::safecopy( '/var/cpanel/cluster/' . $safe_remote_user . '/config/' . $clustermaster, '/var/cpanel/cluster/root/config/' . $clustermaster );
    }

    require Cpanel::Locale;
    my $locale = Cpanel::Locale->get_handle();

    $options{recurse} //= '';
    if ( lc( $options{'recurse'} ) eq 'on' ) {
        require Whostmgr::API::1::Tokens;
        require Cpanel::UUID;
        my %meta;
        my $sanitized_name = Cpanel::UUID::random_uuid();

        #If this fails, then ehh we'll fall back anyways
        Whostmgr::API::1::Tokens::api_token_revoke(
            {
                token_name => "reverse_trust_$sanitized_name",
            }
        );

        my $tok = Whostmgr::API::1::Tokens::api_token_create(
            {
                token_name => "reverse_trust_$sanitized_name",
                'acl-1'    => 'clustering',
            },
            \%meta
        );

        my $access_hash;
        $access_hash = $tok->{token} if ( ref($tok) eq 'HASH' ) && $tok->{token};

        #Fall back to old access hash if we absolutely have to
        my $fall_back = !$access_hash && ( -e $homedir . '/.accesshash' );
        $access_hash = Cpanel::AccessIds::LoadFile::loadfile_as_user( $ENV{'REMOTE_USER'}, $homedir . '/.accesshash' ) if $fall_back;

        if ($access_hash) {
            local $whm->{'timeout'} = 20;    #if it take more then 20 seconds it should not be part of the cluster
            if ( $whm->addtocluster( $safe_remote_user, $NAT_local_ip, $access_hash, $selfversion ) ) {
                $success_msg .=
                    $fall_back
                  ? $locale->maketext( "The reverse trust relationship has been established from the remote server to this server as well using API token named “[_1]”.", "reverse_trust_$sanitized_name" ) . "\n"
                  : $locale->maketext("The reverse trust relationship has been established from the remote server to this server as well.") . "\n";
            }
            else {
                # This still applies, as it is an attempt with the accesshash instead of an api token.
                $notices .= $locale->maketext("The reverse trust relationship could not be established from the remote server to this server.") . "\n";
                $notices .= $locale->maketext("You must log into the remote server and manually add this server using the “DNS Cluster” interface there if you want the other server to access this one.") . "\n";
            }
        }
        else {
            $notices .= $locale->maketext( "An API token named “[_1]” could not be created.", "reverse_trust_$sanitized_name" ) . "\n";
            $notices .= $locale->maketext("You must log into the remote server and manually add this server using the “DNS Cluster” interface there if you want the other server to access this one.") . "\n";
        }
    }

    if ($dnsrole) {
        require Cpanel::DNSLib::PeerConfig;
        my ( $status, $statusmsg ) = Cpanel::DNSLib::PeerConfig::change_dns_role( $clustermaster, $dnsrole, $user );
        $notices .= $statusmsg . "\n" unless $status;
    }

    $options{synczones} //= '';
    if ( lc( $options{'synczones'} ) eq 'on' ) {

        #Refresh the caches, since this stuff is likely just reading them directly
        require Cpanel::DNSLib::PeerConfig;
        my @peers = Cpanel::DNSLib::PeerConfig::getdnspeerlist( [qw{write-only sync standalone}], $user, 1 );
        return ( 0, "$clustermaster not present in Peer List (@peers)!  Cannot sync zones." ) unless grep { $_ eq $clustermaster } @peers;

        require Cpanel::ServerTasks;
        my $q_success = Cpanel::ServerTasks::queue_task( ['DNSAdminTasks'], "synczones" );

        #Request nonlocal sync, since this is a new cluster member addition
        if ($q_success) {
            $success_msg .= $locale->maketext("Queued task to synchronize zones.") . "\n";
        }
        else {
            $notices .= $locale->maketext("Something went wrong while queuing the Synczones task. Please check the cPanel error log.") . "\n";
        }
    }

    return 1, $success_msg, $notices, $clustermaster;
}

sub get_config {
    my %config = (
        'options' => [
            {
                'name'        => 'host',
                'type'        => 'text',
                'locale_text' => 'Remote cPanel & WHM DNS host',
            },
            {
                'name'        => 'user',
                'type'        => 'text',
                'locale_text' => 'Remote server username',
            },
            {
                'name'        => 'pass',
                'type'        => 'bigtext',
                'locale_text' => 'Remote server API token',
            },
            {
                'name'        => 'recurse',
                'locale_text' => 'Setup Reverse Trust Relationship',
                'type'        => 'binary',
                'default'     => 1,
            },
            {
                'name'        => 'synczones',
                'locale_text' => 'Synchronize Zones Immediately',
                'type'        => 'binary',
                'default'     => 1,
            },
            {
                'name'        => 'debug',
                'locale_text' => 'Debug mode',
                'type'        => 'binary',
                'default'     => 0,
            },
        ],
        'name' => 'cPanel',
    );

    return wantarray ? %config : \%config;
}

1;
