#!/usr/bin/perl

use Getopt::Long;
use HTFeed::DBTools;
use HTFeed::XMLNamespaces qw(register_namespaces :namespaces);
use HTFeed::Volume;
use XML::LibXML;
use List::MoreUtils qw(uniq);
use PREMIS;
use strict;

# get some options:
#   - volume we are recording the exception for
#   - types of exceptions being recorded (comma separated list)

#   remove an exception previously recorded
#   display existing exceptions (default)
#   add to existing exceptions (default)
#   replace existing exceptions
#   user to record exception as (default: username@umich.edu)

my @allowed_exceptions = qw(jpeg2000_dimensions tiff_resolution);
my $help = 0;
my $display = 1;
my $replace = 0;
my $remove = 0;

GetOptions(
    'help|?' => \$help,
    'display!' => \$display,
    'replace|r!' => \$replace,
) or pod2usage(2);

pod2usage(1) if $help;

my $objid = shift;
pod2usage(1) if not defined $objid;
my $namespace = 'miun';
$namespace = 'miua' if($objid =~ /^\d{3}/);
my $uniqname =  getpwuid($<);

my $volume = new HTFeed::Volume(pkgtype => 'dlxs', namespace => $namespace, objid => $objid);

# get the existing exceptions, if any, unless replacing
my ( $eventid, $datetime, $outcome,$custom ) = $volume->get_event_info('note_from_mom');
my @existing_exceptions = ();

if($custom and ($display or !$replace)) {
    my $xc = new XML::LibXML::XPathContext($custom);
    register_namespaces($xc);

    foreach my $exception ($xc->findnodes('//ht:exceptionsAllowed/@category')) {
        push(@existing_exceptions,$exception->getValue());
    }

    if(@existing_exceptions and $display) {
        print "$objid: Existing exceptions: ", join (", ", @existing_exceptions), "\n";
    }
}

if($display and !@existing_exceptions) {
    print "$objid: No existing exceptions\n";

}

my @new_exceptions = @ARGV;
foreach my $new_exception (@new_exceptions) {
    pod2usage(2) if(!grep {$_ eq $new_exception} @allowed_exceptions);
}

if(@new_exceptions) {
# create a new PREMIS event w/ custom agent, outcome
    my $event_type = 'manual inspection';
    my $event_id = $volume->make_premis_uuid($event_type);
    my $event_date = $volume->_get_current_date();
    my $event = new PREMIS::Event( $event_id, 'UUID',
        $event_type, $event_date, 'Manually inspect item for completeness and legibility');

    my $outcome = new PREMIS::Outcome('validation exception granted');

# record detail:
#        	<PREMIS:eventOutcomeDetailExtension>
#            	<HT:exceptionsAllowed category="jpeg2000_dimensions” />
#			<HT:exceptionsAllowed category=”sequence_skip” />
#        	</PREMIS:eventOutcomeDetailExtension>

    my $detail_node = PREMIS::createElement("eventOutcomeDetail");
    my $ext_node = PREMIS::createElement("eventOutcomeDetailExtension");
    $detail_node->appendChild($ext_node);

    my @to_record = @new_exceptions;
    push (@to_record, @existing_exceptions) if(!$replace);
    @to_record = uniq(sort(@to_record));

    foreach my $exception (@to_record) {
        my $exception_node = new XML::LibXML::Element("exceptionsAllowed");
        $exception_node->setNamespace(NS_HT,'HT');
        $exception_node->setAttribute("category",$exception);
        $ext_node->appendChild($exception_node);
    }
    push(@{$outcome->{'detail'}},$detail_node);

    $event->add_outcome($outcome);

    $event->add_linking_agent(
        new PREMIS::LinkingAgent( 'Person',
            "$uniqname\@umich.edu",
            'Inspector' ) );

#    print $event->to_node()->toString(1);
    $volume->record_premis_event('note_from_mom',custom_event => $event->to_node());

    print "$objid: Exceptions set to: ", join(", ",@to_record), "\n";
}

if($replace and !@new_exceptions) {
    $volume->remove_premis_event('note_from_mom');
    print "$objid: Removed all exceptions\n";
}
