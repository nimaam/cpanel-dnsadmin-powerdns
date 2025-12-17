package Cpanel::NameServer::DNSSEC::SyncKeys::Queue;

# cpanel - Cpanel/NameServer/DNSSEC/SyncKeys/Queue.pm        Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

=encoding utf-8

=head1 NAME

Cpanel::NameServer::DNSSEC::SyncKeys::Queue

=head1 SYNOPSIS

(See subclasses.)

=head1 DESCRIPTION

This cache is used to queue up the syncing of DNSSEC keys to a DNS cluster.

=cut

use parent qw( Cpanel::TaskQueue::SubQueue );

our $_DIR = '/var/cpanel/taskqueue/groups/dnssec_sync_keys';

sub _DIR { return $_DIR; }

1;
