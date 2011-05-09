#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use SOAP::Lite;
use HTFeed::Config;
use HTFeed::DBTools;
use HTFeed::Volume;
use Mail::Mailer;
use Getopt::Long;

my $dry_run = 0;

GetOptions ("dry-run|n" => \$dry_run);

if($dry_run) {
    print "Dry run -- not updating jira or queue\n";
} 

my $service = SOAP::Lite->service(get_config('jira','wsdl'));

my $token = $service->login(get_config('jira','username'),get_config('jira','password'));
print "Logged in, token = $token\n";

my $issues = $service->getIssuesFromJqlSearch($token,'"Next Steps" = "HT to queue"',1000);

my $dbh = HTFeed::DBTools::get_dbh();
my $queue_sth = $dbh->prepare("insert into mdp_tracking.book_queue select ht_namespace, barcode, 1, \
    scan_date, process_date, NULL, CURRENT_TIMESTAMP \
    from mdp_tracking.grin where ht_namespace = ? and barcode = ?");

my $grin_sth = $dbh->prepare("select state,overall_error,conditions,src_lib_bibkey,\
    dl_date,process_date,analyze_date, \
    (dl_date - process_date) < 0 as reprocessed, \
    (dl_date - analyze_date) < 0 as reanalyzed \
    from mdp_tracking.grin where ht_namespace = ? and barcode = ?");

foreach my $issue (@$issues) {
    my $key = $issue->{key};
    print STDERR "Working on $key", "\n";
    my $url = '';
    my @results;
    my $had_error = 0;


    my @urls = get_item_urls($issue);

    if(!@urls) {
        print STDERR "Item URL missing/empty?\n";
        push(@results,"Item URL missing/empty?");
        $had_error++;
    }

    foreach my $url (@urls) {
        # trim whitespace from URL
        $url =~ s/^\s*(\S+)\s*$/$1/g;

        print STDERR "\tWorking on $url\n";
        my ($volume, $namespace, $objid);
        eval {
            $volume = extract_volume($url);
            $namespace = $volume->get_namespace();
            $objid = $volume->get_objid();
        };
        if($@) {
            push (@results,"Bad ID for $url: $@");
            $had_error++;
            next;
        }

        # Check GRIN to make sure object is enqueuable
        $grin_sth->execute($namespace,$objid);
        my ($state,$err,$condition,$src,$dl_date,
            $process_date,$analyze_date,$reprocessed,$reanalyzed) = $grin_sth->fetchrow_array();
        my $zip_file = $volume->get_repository_zip_path();
        if(-e $zip_file) {
            my $zipdate = (stat($zip_file))[9];
#            push (@results,"$namespace.$objid zip file date is " . scalar(localtime($zipdate)));
        } else {
            push (@results,"$namespace.$objid not previously ingested");
        }
#        push (@results,"$namespace.$objid download date is $dl_date") if defined $dl_date; 
#        push (@results,"$namespace.$objid process date is $process_date") if defined $process_date;
#        push (@results,"$namespace.$objid analyze date is $analyze_date") if defined $analyze_date;
        push (@results,"$namespace.$objid has been analyzed since it was last downloaded") if $reanalyzed;
        push (@results,"$namespace.$objid has been processed since it was last downloaded") if $reprocessed;
        if(not defined $state) {
            push(@results,"$namespace.$objid not found in GRIN");
            $had_error++;
            next;
        }
        if($state ne 'CONVERTED' && $state ne 'NEW' && $state ne 'PREVIOUSLY_DOWNLOADED' && $state ne 'IN_PROCESS') {
            push (@results,"$namespace.$objid has unexpected GRIN state $state\n");
            $had_error++;
            next;
        }
        if(defined $src and $src ne '') {
            push (@results,"$namespace.$objid appears to be a surrogate: $src\n");
            $had_error++;
            next;
        }
        if(defined $reprocessed and !$reprocessed and defined $reanalyzed and !$reanalyzed) {
            push (@results,"$namespace.$objid has not been processed or analyzed since downloading -- not queueing\n");
            $had_error++;
            next;
        }

        # Enqueue
        my $outcome;

        if(!$dry_run) {
            eval {
                my $rows = $queue_sth->execute($namespace,$objid);
                if($rows eq '0E0') {
                    push (@results,"$namespace.$objid unexpected error queueing -- couldn't queue even though found in GRIN?\n");
                    $had_error++;
                } else {
                    push (@results,"$namespace.$objid queued");
                    push (@results,"");
                }
            };
            if($@) {
                if($@ =~ /Duplicate entry/) {
                    push (@results, "$namespace.$objid already in queue");
                } else {
                    push (@results, "$namespace.$objid error queueing -- $@");
                }
            }
        } else {
            print "Dry run - would queue $namespace.$objid\n";
        }

    }

    if(!$dry_run) {
        # Send mail to update ticket
        my $mailer = new Mail::Mailer;
        my $next_steps = ($had_error ? "UM to investigate further" : "HT to reingest");
        my $comment = join("\n",@results);
        print STDERR "$key next step: $next_steps\n $comment\n\n";
        $mailer->open({ 'From' => 'aelkiss@umich.edu',
                'Subject' => "($key): Queueing results",
                'To' => 'feedback@issues.hathitrust.org' });

        print $mailer <<EOT;

Next Steps: $next_steps

$comment

EOT
$mailer->close() or warn("Couldn't send message: $!");
        }

        print "\n($key): Queueing results - error = $had_error\n";
        print join("\n",@results);
        print "\n\n";


    }

# ----------------------
# Check on queued items
# ---------------------

    my $queue_status_sth = $dbh->prepare("select datediff(CURRENT_TIMESTAMP,q.lastupdate) as age, g.state, q.statusid, s.status_description, q.lastupdate, es.error_name, e.description from mdp_tracking.book_queue q left join mdp_tracking.errors e on q.namespace = e.namespace and q.barcode = e.barcode join mdp_tracking.status s on q.statusid = s.statusid join mdp_tracking.grin g on q.barcode = g.barcode and q.namespace = g.ht_namespace left join mdp_tracking.error_status es on e.errorid = es.errorid where q.namespace = ? and q.barcode = ?;");


    $issues = $service->getIssuesFromJqlSearch($token,'"Next Steps" = "HT to reingest"',1000);

    ISSUE: foreach my $issue (@$issues) {
        my $key = $issue->{key};
        print STDERR "Checking on $key", "\n";
        my $url = '';

        my @results;
        my @urls = get_item_urls($issue);
        my $report = 1;

        if(!@urls) {
            print STDERR "Item URL missing/empty?\n";
            push(@results,"Item URL missing/empty?");
        }

        foreach my $url (@urls) {
            $url =~ s/^\s*(\S+)\s*$/$1/g;

            my ($volume, $namespace, $objid);
            print STDERR "\tWorking on $url\n";
            eval {
                $volume = extract_volume($url);
                $namespace = $volume->get_namespace();
                $objid = $volume->get_objid();
            };
            if($@) {
                push (@results,"Bad ID '$namespace.$objid': $@");
                next;
            }

            # Check GRIN to make sure object is enqueuable
            $queue_status_sth->execute($namespace,$objid);
            my ($age, $state, $statusid, $statusdesc, $lastupdate, $errorid, $errordesc) = $queue_status_sth->fetchrow_array();
            if(not defined $age) {
                # Not in queue, so hopefully reingested. Get date from filesystem
                my $zip_file = $volume->get_repository_zip_path();
                if(-e $zip_file) {
                    my $date = (stat($zip_file))[9];
                    if(time() - $date < 86400) {
                        # wait to report - zip file not yet synched
                        $report = 0;
                    } 
                    push(@results,"$namespace.$objid ingested; zip file date " . scalar(localtime($date)));
                } else {
                    push(@results,"$namespace.$objid not in queue, but not in repository either");
                }
            } else {
                # Still in the queue. Was there an error?
                if($statusid eq  '9') {
                    push(@results,"$namespace.$objid failed ingest in $errorid: $errordesc");
                }
                # Has it been sitting in the queue too long?
                elsif($age > 7) {
                    push(@results,"$namespace.$objid stuck in queue -- status is '$statusdesc' last updated $lastupdate; GRIN state is $state");
                } else {
                    $report = 0;
                    push(@results,"$namespace.$objid waiting for reingest -- status is '$statusdesc' last updated $lastupdate; GRIN state is $state");
                    # next ISSUE;
                }
            }
        }

        print "\n\nResults for $key; report = $report:\n";
        print join("\n",@results), "\n\n\n";

        if($report and !$dry_run) {
            my $mailer = new Mail::Mailer;
            my $comment = join("\n",@results);
            $mailer->open({ 'From' => 'aelkiss@umich.edu',
                    'Subject' => "($key): Ingest results",
                    'To' => 'feedback@issues.hathitrust.org' });

            print $mailer <<EOT;
Next Steps: UM to investigate further

$comment

EOT
$mailer->close() or warn("Couldn't send message: $!");
    }

}



# -------------------

sub get_item_urls {
    my $issue = shift;
    my @urls;
    # Get the 'item URL' custom field (customfield_10010)
    foreach my $customField ( @{$issue->{'customFieldValues'}} ) {
        if($customField->{'customfieldId'} eq 'customfield_10040') {
            my $url = $customField->{'values'}->[0];
            @urls = split(/\s*;\s*/, $url);
        }
    }
    return @urls;
}

# Extract the item ID and create a volume from the item URL
sub extract_volume {
    # Try to extract ID from item ID
    my $url = shift;
    my $id = $url;
    if($url =~ /babel.hathitrust.org.*id=(.*)/) {
        $id = $1;
    } elsif($url =~ /hdl.handle.net\/2027\/(.*)/) {
        $id = $1;
    }

    $id =~ /(\w{0,4})\.(.*)/ or die("Can't parse item URL");

    return new HTFeed::Volume(packagetype => 'google',
        namespace => $1,
        objid => $2);
}
