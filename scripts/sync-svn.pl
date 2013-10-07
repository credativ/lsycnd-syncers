#!/usr/bin/perl

#
# sync-svn: implements a three-stage svn sync via ssh
#
# This script aims at implementing a svn synchronisation via rsync/ssh which keeps
# the sync target consistent, while the synchronisation is happening. For this
# it does a three-stage-sync:
#
# 1. Create a snapshot of the local repository to a temporary location
# 2. Sync the snapshot to the remote site into a staging location
# 3. Replace the remote repository (if existing) with the staging copy,
#    while keeping the old repository as the new staging location
#
# Only the first sync is a full-sync, since a staging location is kept after
# the initial sync, which is one version behind the current repository version.
# This allows doing the steps in step 3 atomically, while still providing a
# good tradeoff in terms of transport efficiency.
#
# (C) 2013 credativ GmbH <info@credativ.de>
#
# Author: Patrick Schoenfeld <patrick.schoenfeld@credativ.de>

use strict;
use warnings;

use Net::OpenSSH;
use Getopt::Long;
use File::Rsync;
use File::Copy;
use File::DirCompare;
use File::Spec;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use File::Basename qw(dirname basename);

my $debug=0;
GetOptions(
    "debug|d" => \$debug
);

my ($source, $target) = @ARGV;
if (not $source or not $target) {
    die "$0: source and target arguments are required";
}

my $targethost;
if ($target =~ /^(.*):(.*)/) {
    $targethost = $1;
    $target  = $2;
    print "Syncing $source to $target on $targethost\n";
} else {
    die "$0: unable to guess target host from destination argument";
}

sub dbg {
    print STDERR "DEBUG: " . shift . "\n" if $debug;
}

sub get_remote_rev {
    my ($ssh, $target) = @_;

    # <repo>/db/current may or may not exist, depending on weither
    # a first sync has happened or not, so check it, before reading
    # its content for the current revision
    my $current_path = sprintf("%s/db/current", $target);
    my $res = $ssh->capture(
        "if [ -f $current_path ]; then cat $current_path; else echo false; fi"
    );
    $ssh->error and
        die "error: " . $ssh->error;
    chomp($res);

    if ($res eq "false") {
        return undef; # no current file means: no repository
    } else {
        return $res;
    }
}

sub get_snapshot_name {
    my ($dir) = @_;
    
    $dir = File::Spec->canonpath($dir);

    my (undef, $directories, $file) = File::Spec->splitpath($dir);
    $dir = File::Spec->join($directories, ".sync.".basename($dir));

    return $dir;
}


sub init_sync_check {
    my ($host, $target) = @_;
    my $local_rev = read_file($source . "/db/current");
    chomp $local_rev;

    # TODO: test osf_master file?
    my $remote_rev = get_remote_rev($host, $target);

    return 2
        unless $remote_rev;     # sync, since their is no repo on the remote site

    return 1
        if ($remote_rev < $local_rev);  # sync, since local is newer than remote

    if ($remote_rev == $local_rev) {
        print "Already uptodate.\n";
        exit(0);
    }

    if ($remote_rev >= $local_rev) {
        print STDERR "Remote is newer then local.";
        exit(1); # TODO: Is this really an error?
    }
}

sub sync_svn {
    my ($src, $target, $no_twostagesync) = @_;

    # This method syncs a svn repository with a process as stated
    # on http://svn.apache.org/repos/asf/subversion/trunk/notes/fsfs
    # Meaning:
    #
    # 1) Sync db/current file first
    # 2) Sync the rest afterwards (except transaction and log-files, since
    # those are of a temporary nature)
    #
    # If a remote repository does not exist yet, this method does not make
    # much sense and doesn't even work, so this sub supports a way of avoiding
    # two-stage-sync, if third argument is given.
    my @excludes = ( 'db/transactions/*', 'db/log.*' );
    my $rsync = File::Rsync->new( { archive => 1, delete => 1 } );
    unless ($no_twostagesync) {
        dbg "rsync $src/db/current => $target/db/current";
        $rsync->exec( { src => "$src/db/current", dest => "$target/db/current" } );

        # add db/current to excludes for "rsync of the rest"
        push(@excludes, "db/current");
    } 

    $rsync->exec( { src => "$src/", dest => $target, exclude => \@excludes } );


    $rsync->err
        and die $rsync->err;
}

sub dirs_equal {
    my ($dir1, $dir2) = @_;
    
    my $equal = 1;
    if (not -d $dir2) {
        $equal = 0;
    } else {
        File::DirCompare->compare($dir1, $dir2,
            sub {
                $equal = 0; # every call of the sub indicates a change
            }
        );
    }

    return $equal;
}

sub prep_local_snapshot {
    my ($source, $source_copy) = @_;

    dbg "prep_local_snapshot: source $source => source_copy: $source_copy"; 
    # Do rsync until source and local snapshot are equal, so we are sure we have
    # a sane state.
    do {
        sync_svn($source, $source_copy, 1);
    } while (dirs_equal($source, $source_copy) != 1);
}

sub do_sync {
    my ($ssh, $host, $r_snapshot, $source, $fullsync) = @_;

    my $destination = sprintf("%s:%s", $host, $r_snapshot);
    sync_svn($source, $destination, $fullsync);
}

sub commit_remote {
    my ($ssh, $target, $remote_snapshot) = @_;

    my $res = $ssh->capture(
        "if [ -d $target ]; then mv $target $target.bak; fi"
    );

    $ssh->capture(
        "mv $remote_snapshot $target"
    );

    $ssh->capture(
        "if [ -d $target.bak ]; then mv $target.bak $remote_snapshot; else cp -r $target $remote_snapshot; fi"
    );
}

my $ssh = Net::OpenSSH->new($targethost);
$ssh->error and
    die "Couldn't establish SSH connection: ". $ssh->error;

my $remote_state = init_sync_check($ssh, $target);
my $allatonce    = ($remote_state == 2) ? 1 : 0;


my $local_snapshot  = get_snapshot_name($source);
my $remote_snapshot = get_snapshot_name($target);

# Create a snapshot of the source repository
prep_local_snapshot($source, $local_snapshot);
# Synchronize snapshot of the source repository to remote snapshot
do_sync($ssh, $targethost, $remote_snapshot, $local_snapshot, $allatonce);
# ... and replace target with the previously synced snapshot
commit_remote($ssh, $target, $remote_snapshot);


