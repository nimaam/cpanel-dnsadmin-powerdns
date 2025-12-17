package Cpanel::NameServer::DNSSEC::SyncKeys::Harvester;

# cpanel - Cpanel/NameServer/DNSSEC/SyncKeysHarvester.pm
#                                                    Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

=encoding utf-8

=head1 NAME

Cpanel::NameServer::DNSSEC::SyncKeys::Harvester

=head1 SYNOPSIS

    my $actions = Cpanel::NameServer::DNSSEC::SyncKeys::Harvester->harvest();

=head1 DESCRIPTION

Harvests the synckeys actions from the queue for processing.

=cut

use parent qw(
  Cpanel::NameServer::DNSSEC::SyncKeys::Queue
  Cpanel::TaskQueue::SubQueue::Harvester
);

1;
