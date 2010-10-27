#!/usr/bin/perl

package HTFeed::METS;
use strict;
use warnings;
use METS;
use PREMIS;
use HTFeed::XMLNamespaces qw(:namespaces :schemas);
use Carp;
use Log::Log4perl qw(get_logger);
use Exporter;
use Time::localtime;
use Cwd qw(cwd);
use HTFeed::Config qw(get_config);
use Date::Manip;


use base qw(HTFeed::Stage Exporter);

my $logger = get_logger(__PACKAGE__);

sub new {
    my $class  = shift;

    my $self = {
	volume => undef,
	@_,

	#		files			=> [],
	#		dir			=> undef,
	#		mets_name		=> undef,
	#		mets_xml		=> undef,
	eventids => {},
    };

    croak("Volume parameter required") unless defined $self->{volume};

    bless( $self, $class );
    return $self;
}

sub run_stage {
    my $self = shift;
    my $mets = new METS( objid => $self->{volume}->get_identifier() );
    $self->{'mets'} = $mets;

    my $olddir = cwd();
    my $stage_path = $self->{volume}->get_staging_directory();
    chdir($stage_path) or die("Can't chdir $stage_path: $!");

    eval {
        $self->_add_schemas();
        $self->_add_header();
        $self->_add_dmdsecs();
        $self->_add_techmds();
        $self->_add_filesecs();
        $self->_add_struct_map();
        $self->_add_premis();
        $self->_save_mets();
    };
    if($@) {
	$self->_set_error("METS creation failed",detail=>$@);
    }
    $self->_set_done();

    chdir($olddir) or die("Can't restore $olddir: $!");

}

sub _add_schemas {
    my $self = shift;
    my $mets = $self->{mets};

    $mets->add_schema( "PREMIS", NS_PREMIS, SCHEMA_PREMIS );
    $mets->add_schema( "MARC",   NS_MARC,   SCHEMA_MARC );

}

sub _add_header {
    my $self = shift;
    my $mets = $self->{mets};

    my $header = new METS::Header(
        createdate   => _get_createdate(),
        recordstatus => 'NEW',
	id => 'HDR1',
    );
    $header->add_agent(
        role => 'CREATOR',
        type => 'ORGANIZATION',
        name => 'DLPS'
    );

    $mets->set_header($header);

    # Google: altRecordID handling - reject if there is an altRecordID in the
    # source METS. This should only happen if the volume is a duplicate, which
    # should be detected by looking for condition 31 set and source library
    # bibkey not null, but it doesn't hurt to check.

    # IA: add an altRecordID with the IA identifier
}

sub _add_dmdsecs {
    my $self   = shift;
    my $volume = $self->{volume};
    my $mets   = $self->{mets};

    my $dmdsec =
      new METS::MetadataSection( 'dmdSec',
        'id' => $self->_get_subsec_id("DMD") );
    $dmdsec->set_md_ref(
        mdtype       => 'MARC',
        loctype      => 'OTHER',
        otherloctype => 'Item ID stored as second call number in item record',
        xptr => $volume->get_identifier()
    );
    $mets->add_dmd_sec($dmdsec);

    $dmdsec =
      new METS::MetadataSection( 'dmdSec',
        'id' => $self->_get_subsec_id("DMD") );
    $dmdsec->set_data(
        $volume->get_marc_xml(), # will throw an exception if no MARC found
        mdtype => 'MARC',
        label  => 'Physical volume MARC record'
    );
    $mets->add_dmd_sec($dmdsec);

    # MIU: add TEIHDR; do not add second call number??
}

sub _add_techmds {

    # Google: notes.txt and pagedata.txt should no longer be present

    # MIU: loadcd.log, checksum, pageview.dat, target files?

    # UMP: PDF????!?!?!?

}

# extract existing PREMIS events from object currently in repos
sub _extract_old_premis {
    my $self = shift;
    my $volume = $self->{volume};

    my $mets_in_repos = $volume->get_repository_mets_path();
    my $old_events = [];

    if(defined $mets_in_repos) {
        # validate METS in repository
        my ($mets_in_rep_valid,$val_results) = validate_xml($self->{'config'},$mets_in_repos);
        if($mets_in_rep_valid) {
	    my $xc = $volume->get_repos_mets_xpc();

	    foreach my $event ($xc->findnodes('//PREMIS:event')) {

		my $eventType = $xc->findvalue("./PREMIS:eventType",$event);
		my $eventId = $xc->findvalue("./PREMIS:eventIdentifier/PREMIS:eventIdentifierValue",$event);

		$self->_set_error("PREMIS in repository invalid", 
		    detail => "Missing eventType", node => $event->toString()) unless defined $eventType and $eventType;
		$self->_set_error("PREMIS in repository invalid", 
		    detail => "Missing eventIdentifierValue", node => $event->toString()) unless defined $eventId and $eventId;

		# Extract event count and make sure we don't try to reuse identifier
		if($eventId =~ /^(\D+)(\d+)$/) {
		    my ($eventid_type, $eventIdCount) = ($1,$2);
		     if(not defined $self->{'eventids'}{$eventid_type}) {
			 $self->{'eventids'}{$eventid_type} = 0;
		     }

		     if($eventIdCount > $self->{'eventids'}{$eventid_type}) {
			 $self->{'eventids'}{$eventid_type} = $eventIdCount;
		     }

		} else {
		    $self->_set_error("PREMIS in repository invalid",
			detail => "Malformed event ID $eventId");
		}

		push @{$self->{store_events}{$eventType}}, $event;
		push @{ $old_events }, $event
	    }

	    return $old_events;

        }
        else {
	    # TODO: should be warning, not error
	    $self->_set_error("METS in repository invalid", detail => $val_results);
	    print "$val_results";
        }
    }
}

sub _add_premis {
    my $self = shift;
    my $volume = $self->{volume};
    my $nspkg = $volume->get_nspkg();

    my $premis = new PREMIS;

    my $old_events = $self->_extract_old_premis();
    if ($old_events) {
	foreach my $old_event (@$old_events) {
	    $premis->add_event($old_event);
	}
    }

    my $xc = $volume->get_source_mets_xpc();
    my $src_premis_events = {};
    foreach my $src_event ($xc->findnodes('//PREMIS:event')) {
	# src event will be an XML node
        # do we want to keep this kind of event?
	my $event_type = $xc->findvalue('./PREMIS:eventType',$src_event);
	$src_premis_events->{$event_type} = [] if not defined $src_premis_events->{$event_type};
	push(@{ $src_premis_events->{$event_type} }, $src_event);
    }

    foreach my $eventtype ( @{ $nspkg->get('source_premis_events') } ) {
	next unless defined $src_premis_events->{$eventtype};
	foreach my $src_event ( @{ $src_premis_events->{$eventtype} } ) {
	    my $datetime = $xc->findvalue('./PREMIS:eventDateTime',$src_event);
	    if($self->_need_to_update_event($eventtype,$datetime)) {
		# fix up the source METS event ID and event ID type
		my $eventid = $self->_get_next_eventid($eventtype);
		my $found_eventid_node = 0;
		my $found_eventid_type = 0;
		my $found_eventid_value = 0;
		foreach my $eventid_node( $src_event->getChildrenByTagNameNS(NS_PREMIS,'eventIdentifier')) {
		    $found_eventid_node++;

		    foreach my $eventid_type ($eventid_node->getChildrenByTagNameNS(NS_PREMIS,'eventIdentifierType')) {
			$eventid_type->removeChildNodes();
			$eventid_type->appendText('UM');
			$found_eventid_type++;
		    }
		    foreach my $eventid_value ($eventid_node->getChildrenByTagNameNS(NS_PREMIS,'eventIdentifierValue')) {
			$eventid_value->removeChildNodes();
			$eventid_value->appendText($eventid);
			$found_eventid_value++;
		    }
		}
		$self->_set_error("PREMIS in source METS invalid",detail=>"Error updating event identifier in event",node => $src_event->toString()) 
		    unless ($found_eventid_node == 1 && $found_eventid_type == 1&& $found_eventid_value == 1);
		$premis->add_event($src_event);

	    }
	}
    }

    # create PREMIS object
    my $premis_object = new PREMIS::Object('identifier',$volume->get_identifier());
    $premis_object->set_preservation_level("1");
    $premis_object->add_significant_property('file count',$volume->get_file_count());
    $premis_object->add_significant_property('page count',$volume->get_page_count());
    $premis->add_object($premis_object);

    # last chance to record, even though it's not done yet
    $volume->record_premis_event('ingestion');

    foreach my $eventcode (@{$nspkg->get('premis_events')}) {
	# query database for: datetime, outcome
	my ($datetime, $outcome) = $volume->get_event_info($eventcode);
	$self->_set_error("Missing datetime for $eventcode") if not defined $datetime;
	my $eventconfig = $nspkg->get_event_configuration($eventcode);

	my $executor = $eventconfig->{'executor'} 
	    or $self->_set_error("Missing event executor for $eventcode");
	my $detail = $eventconfig->{'detail'} 
	    or $self->_set_error("Missing event detail for $eventcode");
	my $eventtype = $eventconfig->{'type'}
	    or $self->_set_error("Missing event type for $eventcode");

	$executor = $volume->get_artist() if $executor eq 'VOLUME_ARTIST';

	# don't record event if there's already one of this type at the same or later time
	next unless $self->_need_to_update_event($eventtype,$datetime);

	my $eventid;
	if(defined $eventconfig->{'eventid_override'}) {
	    $eventid = $eventconfig->{'eventid_override'};
	} else {
	    $eventid = $self->_get_next_eventid($eventtype);
	}

	my $event = new PREMIS::Event($eventid, $executor, $eventtype, $datetime, $detail);
	$event->add_outcome(new PREMIS::Outcome($outcome)) if defined $outcome;

	# query namespace/packagetype for software tools to record for this event type
	$event->add_linking_agent(new PREMIS::LinkingAgent('AgentID',$executor,'Executor'));

	my @agents = ();
	my $tools_config = $eventconfig->{'tools'};
	foreach my $agent (@$tools_config) {
	    $event->add_linking_agent(new PREMIS::LinkingAgent('tool',$agent,'software'));
	}
	$premis->add_event($event);

    }
    my $digiprovMD =
      new METS::MetadataSection( 'digiprovMD', 'id' => 'premis1' );
    $digiprovMD->set_xml_node( $premis->to_node(), mdtype => 'PREMIS' );
    $self->{'mets'}->add_amd_sec( 'AMD1', $digiprovMD);

}


sub _get_subsec_id {
    my $self        = shift;
    my $subsec_type = shift;
    $self->{counts} = {} if not exists $self->{counts};
    $self->{counts}{$subsec_type} = 0
      if not exists $self->{counts}{$subsec_type};
    return "$subsec_type" . ++$self->{counts}{$subsec_type};
}

sub _add_filesecs {
    my $self   = shift;
    my $mets   = $self->{mets};
    my $volume = $self->{volume};


    $volume->record_premis_event('zip_md5_create');
    # first add zip
    my $zip_filegroup = new METS::FileGroup(
        id  => $self->_get_subsec_id("FG"),
        use => 'zip archive'
    );
    $zip_filegroup->add_file( $volume->get_zip(), prefix => 'ZIP' );
    $mets->add_filegroup($zip_filegroup);

    # then add the actual content files
    my $filegroups = $volume->get_file_groups();
    $self->{filegroups} = {};
    while ( my ( $filegroup_name, $filegroup ) = each(%$filegroups) ) {
        my $mets_filegroup = new METS::FileGroup(
            id  => $self->_get_subsec_id("FG"),
            use => $filegroup->get_use()
        );
        $mets_filegroup->add_files( $filegroup->get_filenames(),
            prefix => $filegroup->get_prefix() );

        $self->{filegroups}{$filegroup_name} = $mets_filegroup;
        $mets->add_filegroup($mets_filegroup);
    }

    # MIU: Extra stuff for MIU: archival XML, objid XML?

}

sub _add_struct_map {
    my $self   = shift;
    my $mets   = $self->{mets};
    my $volume = $self->{volume};

    my $struct_map = new METS::StructMap( id => 'SM1', type => 'physical' );
    my $voldiv = new METS::StructMap::Div( type => 'volume' );
    $struct_map->add_div($voldiv);
    my $order               = 1;
    my $file_groups_by_page = $volume->get_file_groups_by_page();
    foreach my $seqnum (sort(keys(%$file_groups_by_page))) {
	my $pagefiles = $file_groups_by_page->{$seqnum};
        my $pagediv_ids = [];
        my $pagedata;
	my @pagedata;
        while ( my ( $filegroup_name, $files ) = each(%$pagefiles) ) {
            foreach my $file (@$files) {
                my $fileid = $self->{filegroups}{$filegroup_name}->get_file_id($file);
                croak("Can't find file ID for $file in $filegroup_name")
                  unless defined $fileid;

                # try to find page number & page tags for this page
                if ( not defined $pagedata ) {
                    $pagedata = $volume->get_page_data($fileid);
		    @pagedata = %$pagedata;
                }

                push( @$pagediv_ids, $fileid );
            }
        }
        $voldiv->add_file_div(
            $pagediv_ids,
            order => $order++,
            type  => 'page',
            @pagedata
        );
    }
    $mets->add_struct_map($struct_map);

}

sub _save_mets {
    my $self   = shift;
    my $mets   = $self->{mets};
    my $volume = $self->{volume};

    my $mets_path = $self->{volume}->get_mets_path();

    open( my $metsxml, ">", "$mets_path" )
      or die("Can't open IA METS xml $mets_path for writing: $!");
    print $metsxml $mets->to_node()->toString(1);
    close($metsxml);
}

sub validate {
    my $self      = shift;
    my $mets_path = $self->{volume}->get_mets_path();

    croak("METS file $$self{'filename'} does not exist. Cannot validate.")
      unless -e $mets_path;

    my ( $mets_valid, $val_results ) =
      validate_xml( $self->{'config'}, $$self{'filename'} );
    if ( !$mets_valid ) {
        $self->_set_error(
            "METS file invalid",
            file   => $mets_path,
            detail => $val_results
        );

        # TODO: set failure creating METS file
        return;
    }

}

sub validate_xml {
    my $xerces = get_config('xerces');

    my $filename       = shift;
    my $validation_cmd = "$xerces -f -p $filename 2>&1";
    my $val_results    = `$validation_cmd`;
    if ( $val_results =~ /Error/ || $? ) {
        wantarray ? return ( 0, $val_results ) : return (0);
    }
    else {
        wantarray ? return ( 1, undef ) : return (0);
    }

}

=item _get_createdate $ss1970

Given ss1970, use Time::localtime to generate a date with format: yyyy-mm-ddT13:27:00

=cut

sub _get_createdate {
    my $self = shift;
    my $ss1970 = shift;

    my $localtime_obj = defined($ss1970) ? localtime($ss1970) : localtime();

    my $ts = sprintf("%d-%02d-%02dT%02d:%02d:%02d",
        (1900 + $localtime_obj->year()),
        (1 + $localtime_obj->mon()),
        $localtime_obj->mday(),
        $localtime_obj->hour(),
        $localtime_obj->min(),
        $localtime_obj->sec());

    return $ts;
}

=item _need_to_update_event ($event, $datetime)

Evaluate all datetimes in existing METS file for $event and return true if we
need to add a new event because $datetime is newer than any already in the METS
file (or because there is not an existing METS file to evaluate).

=cut

sub _need_to_update_event {
    my $self = shift;
    my $volume = $self->{volume};
    my $event = shift;
    my $datetime = shift;

    my $date_new = ParseDate($datetime);

    #
    # Look at PREMIS events from METS file in repository. If this dateTime is newer, then we do need to insert a PREMIS:event element for this event.
    #
    # Return 1 if we need to add a <PREMIS:event> element for $datetime
    #
    # Return 0 if we don't need to because a <PREMIS:event> element already exists with this exact datetime
    #
    # Also return 1 if there is not a copy of this volume already in the repository (in which case $$self{'store_events'}{$event} will not exist and we'll never go through the foreach loop, so we'll just return with the $need_to_update default of true).

    my $need_to_update = 1;
    my $xc = $volume->get_repos_mets_xpc();

    foreach my $event_element ( @{$$self{'store_events'}{$event}} ) {

	my $event_dateTime = $xc->findvalue('./premis:eventDateTime',$event_element);

	my $date_existing = ParseDate($event_dateTime);

	my $flag = Date_Cmp($date_new, $date_existing);

	if($flag > 0) {

	    #print "$event: $datetime IS NEWER THAN $event_dateTime SO WE NEED TO ADD A NEW PREMIS EVENT ($flag)\n";

	    $need_to_update = 1;
	}
	elsif ($flag == 0) {

	    #print "$event: $datetime IS IDENTICAL TO $event_dateTime ($flag)\n";

	    $need_to_update = 0;
	}
	else {
	    #print "$event: $datetime IS EARLIER THAN $event_dateTime. That ought to be impossible, so WTF? ($flag)\n";
	}
    }

    return($need_to_update);
}

sub _get_next_eventid {
    my $self = shift;
    my $eventcode = shift;

    if(not defined $self->{'eventids'}{$eventcode}) {
	$self->{'eventids'}{$eventcode} = 0;
    }

    return $eventcode . ++$self->{'eventids'}{$eventcode};
}


1;
