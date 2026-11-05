#!/bin/sh
# Fails on a Swift line under mac/ (tests left out) that turns a rounded floating-point value into an Int without saying
# why it can't trap. Swift's Int(x) traps on NaN, infinity or a value out of range (CODING_STANDARDS.md, "A floating-point
# value is checked finite and in range before it becomes an integer"; Add Watermark's width "inf", a scanner PDF's page
# size). A line is fine when it uses Int(exactly: …) (nil instead of a trap) or carries a `// bounded: <why>` comment
# saying why the value is finite and in range (clamped with NaN handled, a zoom the app sets).
#
#   sh mac/tools/check-int.sh [dir]     dir defaults to the repo's mac/; prints file:line for each offence
#
# Runs on macOS (CI's mac job) and in Git Bash: perl only.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dir=$(cd "${1:-$here/..}" && pwd)
cd "$dir/.."
exec perl -e '
use strict; use warnings; use File::Find;
my ($dir) = @ARGV; my $bad = 0; my @files;
find({ no_chdir => 1, wanted => sub {
    if (-d $_ && m{/(\.build|Tests|Frameworks|Vendor|DerivedData)$}) { $File::Find::prune = 1; return; }
    push @files, $_ if -f $_ && /\.swift$/ && !/Tests?\.swift$/;
} }, $dir);
for my $f (sort @files) {
    open(my $fh, "<", $f) or die "$f: $!";
    while (my $line = <$fh>) {
        next if $line =~ m{//\s*bounded:\s*\S.{2,}};
        (my $l = $line) =~ s/\bInt\(exactly:/(/g;
        next unless $l =~ /\bInt\(.*\.rounded\(/;
        $line =~ s/^\s+|\s+$//g;
        print "$f:$.: $line\n";
        $bad++;
    }
    close $fh;
}
if ($bad) {
    print STDERR "check-int: $bad line(s) turn a rounded Double into an Int that traps on NaN, infinity or a huge value.\n",
        "Use Int(exactly: x.rounded()) with a fallback or a refusal, or add // bounded: <why it is finite and in range>.\n";
    exit 1;
}
print "check-int: no unchecked Int(….rounded()) under $dir/\n";
' "$(basename "$dir")"
