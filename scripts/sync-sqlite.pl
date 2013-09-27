#!/usr/bin/perl

use strict;
use warnings;

use DBI;
use Net::OpenSSH;
use Getopt::Long;
use File::Temp qw(tempfile);
use File::Basename qw(dirname basename);

my $debug=0;
GetOptions(
    "debug|d" => \$debug
);

my ($srcfile, $destination) = @ARGV;
if (not $srcfile or not $destination) {
	die "$0: source and destination arguments are required";
}

if (not -f $srcfile) {
    die "$0: srcfile is not a file/does not exist";
}

my $dsthost;
my $dstdir;
if ($destination =~ /^(.*):(.*)/) {
    $dsthost = $1;
    $dstdir  = $2;
    print "Syncing $srcfile to $dstdir on $dsthost\n";
} else {
    die "$0: unable to guess target host from destination argument";
}

my $outfile             = basename($srcfile);
my ($tmpfh, $tmpfile)   = tempfile();

# Backup database to temporary file
my $dbi_string  = sprintf("dbi:SQLite:dbname=%s", $srcfile);
print "=> connect($dbi_string)\n" if $debug;

my $dbh         = DBI->connect($dbi_string, "", "")
    or die "unable to open database `$srcfile': $!";

print "=> sqlite_backup_to_file($tmpfile)\n" if $debug;
$dbh->sqlite_backup_to_file($tmpfile);

# Sync that temporary file to remote target
print "=> scp_put($tmpfile, $dstdir)\n" if $debug;
my $ssh = Net::OpenSSH->new($dsthost);
$ssh->scp_put($tmpfile, $dstdir)
    or die "unable to transfer file: " . $ssh->error;

# Rename file in remote location
my $rename_command = sprintf("mv %s/%s %s/%s",
    $dstdir,
    basename($tmpfile),
    $dstdir,
    $outfile
);
print "=> Exec '$rename_command' on $dsthost\n" if $debug;
$ssh->system($rename_command)
	or die "unable to rename remote file: " . $ssh->error;
print "success.\n"
