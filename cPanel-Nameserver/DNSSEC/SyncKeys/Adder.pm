package Cpanel::NameServer::DNSSEC::SyncKeys::Adder;

# cpanel - Cpanel/NameServer/DNSSEC/SyncKeys/Adder.pm
#                                                    Copyright 2022 cPanel, L.L.C.
#                                                           All rights reserved.
# copyright@cpanel.net                                         http://cpanel.net
# This code is subject to the cPanel license. Unauthorized copying is prohibited

use strict;
use warnings;

=encoding utf-8

=head1 NAME

Cpanel::NameServer::DNSSEC::SyncKeys::Adder

=head1 SYNOPSIS

    Cpanel::NameServer::DNSSEC::SyncKeys::Adder->add($sync_action_str);

=head1 DESCRIPTION

    Adder to queue a dnssec sync command.

=cut

use parent qw(
  Cpanel::NameServer::DNSSEC::SyncKeys::Queue
  Cpanel::TaskQueue::SubQueue::Adder
);

1;
