#!/usr/bin/env perl
#
# File name: clamdownloader.pl
# Author:    Frederic Vanden Poel
# Enhanced:  Added UA, mirror fallback and CDIFF missing-history cache
#
#############################################################################

use strict;
use warnings;
use Getopt::Long;

use Net::DNS;
use LWP::UserAgent;
use HTTP::Request;
use File::Copy;
use File::Compare;

# Base directory where ClamAV databases are stored
my $clamdb = "/var/www/html/clamav";

# Flag to skip daily.cvd update
my $skip_daily = 0;

# Parse command-line options
GetOptions(
    'skip-daily' => \$skip_daily,
) or die("Error in command-line arguments\n");

# User-Agent string used for HTTP requests
my $user_agent = 'ClamAV/1.4.3 (OS: Linux, ARCH: x86_64, CPU: x86_64, UUID: 98425604-444c-40ae-969a-df296bfa1581)';

# Mirrors that provide full .cvd files (public, no 403)
my @cvd_mirrors = (
    "https://database.clamav.net",
    "https://mirror.truenetwork.ru/clamav",
);

# Mirrors used for incremental .cdiff files
my @cdiff_mirrors = (
    "https://database.clamav.net",
    "https://mirror.truenetwork.ru/clamav",
);

# Cache of CDIFF files known to be unavailable
my %cdiff_history = ();
load_cdiff_history();

# Fetch TXT record containing current database versions
my $txt = getTXT("current.cvd.clamav.net");
exit unless $txt;

# Switch to ClamAV database directory
chdir($clamdb) || die ("Can't chdir to $clamdb : $!\n");

print "TXT from DNS: $txt\n";

# Save DNS TXT record locally for reference/debugging
open my $dns_fh, '>', 'dns.txt' or die "Can't open dns.txt: $!";
print $dns_fh "$txt";
close $dns_fh;

# Temporary directory for downloads
mkdir("$clamdb/temp") unless -d "$clamdb/temp";

# Parse fields from DNS TXT record
my ( $clamv, $mainv, $dailyv, $x, $y, $z, $safebrowsingv, $bytecodev ) = split /:/, $txt;
print "FIELDS main=$mainv daily=$dailyv bytecode=$bytecodev\n";

# Update main database
updateFile('main', $mainv);

# Update daily database unless explicitly skipped
unless ($skip_daily) {
    updateFile('daily', $dailyv);
    updateFileCdiff('daily', $dailyv);
}

# Update bytecode database
updateFile('bytecode', $bytecodev);

# ================== Subroutines ==================

# Retrieve TXT record for a given DNS name
sub getTXT {
    my $domain = shift;
    my $res = Net::DNS::Resolver->new;
    my $txt_query = $res->query($domain, "TXT");

    if ($txt_query) {
        return ($txt_query->answer)[0]->txtdata;
    } else {
        warn "Unable to get TXT Record: ", $res->errorstring, "\n";
        return 0;
    }
}

# Extract local CVD version using sigtool
sub getLocalVersion {
    my $file = shift;
    my $cmd = "sigtool -i $clamdb/$file.cvd 2>/dev/null";

    open my $pipe, '-|', $cmd or die "Can't run $cmd : $!";
    while (<$pipe>) {
        if (/Version: (\d+)/) {
            close $pipe;
            return $1;
        }
    }
    close $pipe;
    return -1;
}

# Download a full .cvd file with mirror fallback and If-Modified-Since support
sub download_file {
    my ($filename, $local_file) = @_;

    for my $mirror (@cvd_mirrors) {
        my $url = "$mirror/$filename";
        print "Trying $url ...\n";

        my $ua = LWP::UserAgent->new(
            agent    => $user_agent,
            timeout  => 30,
            ssl_opts => { verify_hostname => 1 }
        );

        # Send If-Modified-Since header if file already exists
        my $if_modified_since;
        if (-e $local_file) {
            my $mtime = (stat($local_file))[9];
            $if_modified_since = HTTP::Date::time2str($mtime);
        }

        my $request = HTTP::Request->new(GET => $url);
        $request->header('If-Modified-Since' => $if_modified_since) if $if_modified_since;

        my $response = $ua->request($request, $local_file);

        if ($response->is_success) {
            print "✅ Downloaded: $url -> $local_file\n";
            return 1;
        } elsif ($response->code == 304) {
            print "ℹ  File not modified: $local_file\n";
            return 1;
        } else {
            warn "⚠  Failed to download $url: " . $response->status_line . "\n";
            unlink $local_file if -e $local_file;
        }
    }

    warn "❌ All CVD mirrors failed for $filename\n";
    return 0;
}

# Download a .cdiff incremental update file
sub download_cdiff {
    my ($filename, $local_file) = @_;

    for my $mirror (@cdiff_mirrors) {
        my $url = "$mirror/$filename";
        print "Trying CDIFF $url ...\n";

        my $ua = LWP::UserAgent->new(
            agent    => $user_agent,
            timeout  => 30,
            ssl_opts => { verify_hostname => 1 }
        );

        my $response = $ua->get($url);

        if ($response->is_success) {
            open my $out, '>', $local_file or die "Can't write $local_file: $!";
            print $out $response->content;
            close $out;
            print "✅ Downloaded CDIFF: $url -> $local_file\n";
            return 1;
        } elsif ($response->code == 404) {
            print "ℹ  CDIFF not found (404): $url\n";
            next;
        } else {
            warn "⚠  Failed to download CDIFF $url: " . $response->status_line . "\n";
            next;
        }
    }

    print "❌ CDIFF $filename not available on any mirror\n";
    return 0;
}

# Update a database using incremental CDIFFs when possible,
# otherwise fall back to full CVD download
sub updateFile {
    my ($file, $currentversion) = @_;
    my $old = 0;

    # If file does not exist, download full CVD
    if (! -e "$file.cvd") {
        warn "file $file.cvd does not exist, downloading full version...\n";
        if (download_file("$file.cvd", "temp/$file.cvd")) {
            if (-e "temp/$file.cvd" && ! -z "temp/$file.cvd") {
                move("temp/$file.cvd", "$file.cvd") or warn "Move failed: $!";
            } else {
                warn "Downloaded $file.cvd is invalid!\n";
                unlink "temp/$file.cvd" if -e "temp/$file.cvd";
            }
        }
        return;
    }

    # If existing file is valid, try incremental update
    if (! -z "$file.cvd") {
        $old = getLocalVersion($file);

        if ($old > 0 && $old < $currentversion) {
            print "$file old: $old current: $currentversion\n";
            my @missing_diffs;

            # Attempt to download all required CDIFFs
            for (my $count = $old + 1; $count <= $currentversion; $count++) {
                my $key = "$file:$count";

                if ($cdiff_history{$key}) {
                    print "Skipping (known missing): $file-$count.cdiff\n";
                    push @missing_diffs, $count;
                    next;
                }

                my $cdiff_file = "$file-$count.cdiff";
                my $cdiff_result = download_cdiff($cdiff_file, $cdiff_file);

                if ($cdiff_result == 0) {
                    # Mark missing CDIFF to avoid retrying in future runs
                    $cdiff_history{$key} = 1;
                    save_cdiff_history();
                    push @missing_diffs, $count;
                }
            }

            # If any CDIFFs are missing, fall back to full CVD update
            if (@missing_diffs) {
                print "Incremental update not possible for $file (missing: @missing_diffs), falling back to full CVD\n";

                for my $c ($old + 1 .. $currentversion) {
                    unlink "$file-$c.cdiff" if -e "$file-$c.cdiff";
                }

                copy("$file.cvd", "temp/$file.cvd") or warn "Copy failed: $!";
                if (download_file("$file.cvd", "temp/$file.cvd")) {
                    if (-e "temp/$file.cvd" && ! -z "temp/$file.cvd") {
                        if ((stat("temp/$file.cvd"))[9] > (stat("$file.cvd"))[9]) {
                            move("temp/$file.cvd", "$file.cvd") or warn "Move failed: $!";
                        } else {
                            unlink "temp/$file.cvd";
                        }
                    } else {
                        warn "Full $file.cvd is invalid after download!\n";
                        unlink "temp/$file.cvd" if -e "temp/$file.cvd";
                    }
                }
                return;
            }
        }
    } else {
        # Zero-sized file, re-download full version
        warn "file $file.cvd is zero-sized, downloading full version\n";
        download_file("$file.cvd", "temp/$file.cvd");
        if (-e "temp/$file.cvd" && ! -z "temp/$file.cvd") {
            move("temp/$file.cvd", "$file.cvd") or warn "Move failed: $!";
        }
        return;
    }

    # No version change
    return if ($currentversion == $old);

    # Full update if needed
    copy("$file.cvd", "temp/$file.cvd") or warn "Copy failed: $!";
    if (download_file("$file.cvd", "temp/$file.cvd")) {
        if (-e "temp/$file.cvd" && ! -z "temp/$file.cvd") {
            if ((stat("temp/$file.cvd"))[9] > (stat("$file.cvd"))[9]) {
                print "file temp/$file.cvd is newer than $file.cvd\n";
                move("temp/$file.cvd", "$file.cvd") or warn "Move failed: $!";
            } else {
                unlink "temp/$file.cvd";
            }
        } else {
            warn "temp/$file.cvd is not valid, not copying back!\n";
            unlink "temp/$file.cvd";
        }
    }
}

# Download only the latest CDIFF and record if missing
sub updateFileCdiff {
    my ($file, $currentversion) = @_;
    my $fullname = "$file-$currentversion.cdiff";
    my $key = "$file:$currentversion";

    return if $cdiff_history{$key};

    if (! -e $fullname) {
        my $result = download_cdiff($fullname, $fullname);
        if ($result == 0) {
            $cdiff_history{$key} = 1;
            save_cdiff_history();
        }
    }
}

# --------------------------- CDIFF HISTORY HANDLING ---------------------------

# Load list of known-missing CDIFFs from disk
sub load_cdiff_history {
    my $hist_file = "$clamdb/cdiff_history.txt";
    return unless -e $hist_file;

    open my $fh, '<', $hist_file or warn "Can't read history: $!";
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        $cdiff_history{$line} = 1;
    }
    close $fh;
}

# Save known-missing CDIFFs to disk
sub save_cdiff_history {
    my $hist_file = "$clamdb/cdiff_history.txt";
    my @lines = sort keys %cdiff_history;

    open my $fh, '>', $hist_file or die "Can't write history: $!";
    print $fh "$_\n" for @lines;
    close $fh;
}

__END__
