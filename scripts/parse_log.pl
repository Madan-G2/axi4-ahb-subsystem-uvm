#!/usr/bin/env perl
#==============================================================================
# parse_log.pl -- one-line-per-test summary of simulation logs.
#
# Scrapes each log for
#     UVM_ERROR / UVM_FATAL / UVM_WARNING totals (the report-summary lines)
#     failed concurrent assertions, with the property, scope, file:line and the
#         simulation time of the FIRST one
#     the time of the first failure of any kind (assertion or UVM error)
#     the scoreboard line, and whether the driver reported a deliberate injection
#
# The Python regression runner already produces a verdict; this exists for the other
# job a log scraper has, which is to be run by hand on a pile of logs from somewhere
# else ("what failed, and when did it first go wrong?") without importing anything.
#
# USAGE
#     perl parse_log.pl sim/logs/*.log
#     perl parse_log.pl --dir sim/logs [--csv] [--failing]
#
# OPTIONS
#     --dir D     scan D/*.log
#     --csv       comma-separated output
#     --failing   print only logs with at least one error, fatal or assertion failure
#
# A log "fails" here if it has any UVM_ERROR, UVM_FATAL or failed assertion. A
# deliberate-violation (negative) test therefore shows as failing: this script reports
# what the log says, and judging it against what the test expected is run.py's job.
#==============================================================================
use strict;
use warnings;
use Getopt::Long;
# File::Basename on MSYS Perl does not treat a backslash as a separator, and the runner passes
# Windows paths; split on either.
sub basename { my ($p) = @_; $p =~ s{^.*[\\/]}{}; return $p; }

my ($dir, $csv, $failing_only) = ('', 0, 0);
GetOptions('dir=s' => \$dir, 'csv' => \$csv, 'failing' => \$failing_only)
    or die "usage: $0 [--dir D] [--csv] [--failing] LOGS...\n";

my @logs = @ARGV;
if ($dir) {
    opendir(my $dh, $dir) or die "cannot open $dir: $!\n";
    push @logs, map { "$dir/$_" } sort grep { /\.log$/ && !/^(xvlog|xelab|xelab_cov|xsc|neg_)/ } readdir($dh);
    closedir($dh);
}
die "no logs given\n" unless @logs;

my @rows;
for my $log (@logs) {
    open(my $fh, '<', $log) or do { warn "skip $log: $!\n"; next };

    my %r = (file => basename($log), test => '', seed => '', uerr => 0, ufat => 0, uwrn => 0,
             sva => 0, sva_first_t => undef, sva_first_where => '', first_t => undef,
             inject => 0, scb => '');
    my %props;
    my ($pending_t, $pending_where) = (undef, '');

    # <test>_<seed>.log is how the runner names them; the log itself is authoritative
    # for the test name where it says.
    if ($r{file} =~ /^(.*)_(\d+)\.log$/) { ($r{test}, $r{seed}) = ($1, $2); }

    my $note_first = sub { my $t = shift; $r{first_t} = $t if defined $t && (!defined $r{first_t} || $t < $r{first_t}); };

    while (my $line = <$fh>) {
        $line =~ s/\r?\n$//;

        # --- the report summary -------------------------------------------------------
        if    ($line =~ /^UVM_ERROR\s*:\s*(\d+)/)   { $r{uerr} = $1; next }
        elsif ($line =~ /^UVM_FATAL\s*:\s*(\d+)/)   { $r{ufat} = $1; next }
        elsif ($line =~ /^UVM_WARNING\s*:\s*(\d+)/) { $r{uwrn} = $1; next }

        # --- a failed concurrent assertion is two lines:
        #       Time: 145 ns  Started: 145 ns  Scope: ... File: <path> Line: <n>
        #       Error: s1: a_aw_payload_stable violated
        if ($line =~ /^Time:\s*(\d+)\s*ns.*?File:\s*(\S+)\s+Line:\s*(\d+)/) {
            ($pending_t, $pending_where) = ($1, basename($2) . ":$3");
            next;
        }
        if ($line =~ /^Error:\s*(.*)$/) {
            my $msg = $1;
            $r{sva}++;
            (my $key = $msg) =~ s/\b\d+\b/N/g;   # collapse counts; keep names like m0, a_aw_no_4k_cross
            $props{$key}++;
            if (!defined $r{sva_first_t} || (defined $pending_t && $pending_t < $r{sva_first_t})) {
                $r{sva_first_t}     = $pending_t;
                $r{sva_first_where} = $pending_where;
            }
            $note_first->($pending_t);
            ($pending_t, $pending_where) = (undef, '');
            next;
        }

        # --- UVM messages carry the time as '@ <t>:' in picoseconds -----------------------
        if ($line =~ /^UVM_(?:ERROR|FATAL)\s.*?@\s*(\d+):/) {
            $note_first->($1 / 1000.0);
            next;
        }
        $r{inject} = 1 if $line =~ /^UVM_INFO.*\[INJECT\]/;
        if ($line =~ /\[SCB\] checked (.*)$/) { $r{scb} = $1; next }
        if ($line =~ /UVM_TESTNAME=(\w+)/ && !$r{test}) { $r{test} = $1 }
    }
    close($fh);

    $r{props} = join('; ', map { "$_ x$props{$_}" } sort keys %props);
    $r{fail}  = ($r{uerr} || $r{ufat} || $r{sva}) ? 1 : 0;
    push @rows, \%r unless $failing_only && !$r{fail};
}

# ------------------------------------------------------------------------------------
my @cols = qw(test seed result uvm_err uvm_fat uvm_wrn sva first_fail_ns first_sva_at injected);
if ($csv) {
    print join(',', @cols, 'scoreboard'), "\n";
}
else {
    printf "%-30s %5s  %-6s %7s %7s %7s %6s  %13s  %-26s %s\n",
        'TEST', 'SEED', 'RESULT', 'UVM_ERR', 'UVM_FAT', 'UVM_WRN', 'SVA', 'FIRST_FAIL_NS', 'FIRST_SVA(file:line)', 'INJ';
    print '-' x 140, "\n";
}

my ($n, $nfail) = (0, 0);
for my $r (sort { $a->{test} cmp $b->{test} || ($a->{seed} || 0) <=> ($b->{seed} || 0) } @rows) {
    $n++;
    $nfail++ if $r->{fail};
    my $ff = defined $r->{first_t} ? sprintf('%.0f', $r->{first_t}) : '-';
    my $fs = defined $r->{sva_first_t} ? "$r->{sva_first_where}\@$r->{sva_first_t}" : '-';
    if ($csv) {
        print join(',', $r->{test}, $r->{seed}, $r->{fail} ? 'FAIL' : 'PASS', $r->{uerr}, $r->{ufat},
                   $r->{uwrn}, $r->{sva}, $ff, $fs, $r->{inject}, qq("$r->{scb}")), "\n";
    }
    else {
        printf "%-30s %5s  %-6s %7d %7d %7d %6d  %13s  %-26s %s\n",
            $r->{test}, $r->{seed}, $r->{fail} ? 'FAIL' : 'PASS', $r->{uerr}, $r->{ufat},
            $r->{uwrn}, $r->{sva}, $ff, $fs, $r->{inject} ? 'yes' : '';
        printf "      %s\n", $r->{props} if $r->{props};
    }
}
unless ($csv) {
    print '-' x 140, "\n";
    printf "%d log(s), %d with errors, fatals or assertion failures\n", $n, $nfail;
}
exit($nfail ? 1 : 0);
