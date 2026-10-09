#!/usr/bin/perl
# Minimal stand-in for GNU coreutils `timeout [-k KILL] SECS CMD...` (no --foreground):
# runs CMD in its own process group, TERMs that group at SECS, KILLs it KILL seconds later, exits 124.
use strict; use POSIX ":sys_wait_h";
my $k = 0;
if ($ARGV[0] eq '-k') { shift; $k = shift; }
my $secs = shift;
setpgrp(0, 0);
my $pid = fork; die "fork" unless defined $pid;
if (!$pid) { exec @ARGV or exit 127; }
for my $sig (qw(TERM INT HUP)) { $SIG{$sig} = sub { kill $sig, $pid; }; }
my $deadline = time + $secs; my $fired = 0;
while (1) {
  my $r = waitpid($pid, WNOHANG);
  if ($r == $pid) { exit($fired ? 124 : (($? & 127) ? 128 + ($? & 127) : $? >> 8)); }
  if (!$fired && time >= $deadline) { $fired = 1; kill 'TERM', -$$; $deadline = time + $k; }
  elsif ($fired && $k && time >= $deadline) { kill 'KILL', -$$; }
  select undef, undef, undef, 0.05;
}
