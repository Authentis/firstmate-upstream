#!/usr/bin/perl
# A wedged agent (non-shell process): answers every turn with a provider 429 until /exit.
$| = 1;
print "fake agent ready (pid $$)\n";
my $n = 0;
while (my $line = <STDIN>) {
  chomp $line;
  if ($line eq '/exit') { print "bye\n"; exit 0; }
  $n++;
  my @t = localtime; my $ts = sprintf("%02d:%02d:%02d", $t[2], $t[1], $t[0]);
  print "> $line\n  turn $n at $ts\n";
  print '  API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"usage limit reached"}}' . "\n";
}
