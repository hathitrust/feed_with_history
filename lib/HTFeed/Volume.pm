package HTFeed::Volume;

use warnings;
use strict;
use Carp;
use Log::Log4perl qw(get_logger);
use HTFeed::XMLNamespaces qw(register_namespaces);
use HTFeed::Namespace;
use HTFeed::FileGroup;
use XML::LibXML;
use GROOVE::Book;
use HTFeed::Config qw(get_config);
use GROOVE::DBTools;
use Time::localtime;

our $logger = get_logger(__PACKAGE__);

sub new {
    my $package = shift;

    my $self = {
	objid     => undef,
	namespace => undef,
	packagetype => undef,
	@_,

	#		files			=> [],
	#		dir			=> undef,
	#		mets_name		=> undef,
	#		mets_xml		=> undef,
    };

    $self->{groove_book} =
    GROOVE::Book->new( $self->{objid}, $self->{namespace},
	$self->{packagetype} );

    $self->{nspkg} = new HTFeed::Namespace($self->{namespace},$self->{packagetype});

    $self->{nspkg}->validate_barcode($self->{objid}) 
	or croak "Invalid barcode $self->{objid} provided for $self->{namespace}";
	
	my $class = $self->{nspkg}->get('volume_module');

    bless( $self, $class );
    return $self;
}

=item get_identifier

Returns the full identifier (namespace.objid) for the volume

=cut

sub get_identifier {
    my $self = shift;
    return $self->get_namespace() . q{.} . $self->get_objid();

}

=item get_namespace

Returns the namespace identifier for the volume

=cut

sub get_namespace {
    my $self = shift;
    return $self->{namespace};
}

=item get_objid

Returns the ID (without namespace) of the volume.

=cut

sub get_objid {
    my $self = shift;
    return $self->{objid};
}

=item get_file_groups 

Returns a hash of lists containing the logical groups of files within the volume.

For example:

{ 
  ocr => [0001.txt, 0002.txt, ...]
  image => [0001.tif, 0002.jp2, ...]
}

=cut

sub get_file_groups {
    my $self = shift;

    my $book = $self->{groove_book};

    my $filegroups = {};
    $filegroups->{image} = HTFeed::FileGroup->new($book->get_all_images(),
	prefix => 'IMG',
	use=>'image');
    $filegroups->{ocr}   = HTFeed::FileGroup->new($book->get_all_ocr(),
	prefix => 'OCR',
	use => 'ocr');

    if ($book->hocr_files_used()) {
	$filegroups->{hocr} = HTFeed::FileGroup->new($book->get_all_hocr(),
	    prefix => 'XML',
	    use => 'coordOCR')
    }

    return $filegroups;
}

=item get_all_directory_files

Returns a list of all files in the staging directory for the volume's AIP

=cut

sub get_all_directory_files {
    my $self = shift;

    return $self->{groove_book}->get_all_files();
}

=item get_staging_directory

Returns the staging directory for the volume's AIP

=cut

sub get_staging_directory {
    my $self = shift;
    
    my $objid = $self->get_objid();
    return sprintf("%s/%s", get_config(staging=>'memory'), $objid);
}

=item get_download_directory

Returns the directory the volume's SIP should be downloaded to

=cut

sub get_download_directory {
    my $self = shift;
    my $dl_to_disk = $self->get_nspkg()->get('download_to_disk');
    if ($dl_to_disk){
        return get_config('staging'=>'disk');
    }
    return get_config('staging'=>'memory');
}

=item get_all_content_files

Returns a list of all files that will be validated.

=cut

sub get_all_content_files {
    my $self = shift;
    my $book = $self->{groove_book};

    return [( @{ $book->get_all_images() }, @{ $book->get_all_ocr() },
	@{ $book->get_all_hocr() })];
}

=item get_checksums

Returns a hash of precomputed checksums for files in the package's AIP where
the keys are the filenames and the values are the MD5 checksums.

=cut

sub get_checksums {
    my $self = shift;

    if ( !defined $self->{checksums} ) {
	my $checksums = {};

	my $path = $self->get_staging_directory();
	my $checksum_file = $self->{groove_book}->get_checksum_file();
	if ( defined $checksum_file ) {
	    my $checksum_fh;
	    open( $checksum_fh, "<", "$path/$checksum_file" )
		or croak("Can't open $checksum_file: $!");
	    while ( my $line = <$checksum_fh> ) {
		chomp $line;
		my ( $checksum, $filename ) = split( /\s+/, $line );
		$checksums->{$filename} = $checksum;
	    }
	    close($checksum_fh);
	}
	else {

	    # try to extract from source METS
	    my $xpc = $self->get_source_mets_xpc();
	    foreach my $node ( $xpc->findnodes('//mets:file') ) {
		my $checksum = $xpc->findvalue( './@CHECKSUM', $node );
		my $filename =
		$xpc->findvalue( './mets:FLocat/@xlink:href', $node );
		$checksums->{$filename} = $checksum;
	    }
	}
	$self->{checksums} = $checksums;
    }

    return $self->{checksums};
}

=item get_checksum_file

Returns the name of the file containing the checksums. Useful since that file won't have
a checksum computed for it.

=cut

sub get_checksum_file {
    my $self          = shift;
    my $checksum_file = $self->{groove_book}->get_checksum_file();
    $checksum_file = $self->{groove_book}->get_source_mets_file()
    if not defined $checksum_file;
    return $checksum_file;
}

=item get_source_mets_file

Returns the name of the source METS file

=cut

sub get_source_mets_file {
    my $self = shift;
    my $mets = $self->{groove_book}->get_source_mets_file();
    croak("Could not find source mets file") unless defined $mets and $mets;
    return $mets;
}

=item get_source_mets_xpc

Returns an XML::LibXML::XPathContext with namespaces set up 
and the context node positioned at the document root of the source METS.

=cut

sub get_source_mets_xpc {
    my $self = shift;

    my $mets = $self->get_source_mets_file();
    my $path = $self->get_staging_directory();
    my $xpc;

    eval {
	my $parser = XML::LibXML->new();
	my $doc    = $parser->parse_file("$path/$mets");
	$xpc = XML::LibXML::XPathContext->new($doc);
	register_namespaces($xpc);
    };

    if ($@) {
	croak("-ERR- Could not read XML file $mets: $@");
    }
    return $xpc;

}

=item get_repos_mets_xpc

Returns an XML::LibXML::XPathContext with namespaces set up 
and the context node positioned at the document root of the source METS.

=cut

sub get_repos_mets_xpc {
    my $self = shift;

    my $mets = $self->get_repository_mets_path();
    return unless defined $mets;

    my $xpc;

    eval {
	my $parser = XML::LibXML->new();
	my $doc    = $parser->parse_file("$mets");
	$xpc = XML::LibXML::XPathContext->new($doc);
	register_namespaces($xpc);
    };

    if ($@) {
	croak("-ERR- Could not read XML file $mets: $@");
    }
    return $xpc;

}

=item get_nspkg

Returns the HTFeed::Namespace object that provides namespace & package type-
specific configuration information.

=cut

sub get_nspkg{
    my $self = shift;
    return $self->{nspkg};
}

=item get_metadata_files

Get all files that will need to have their metadata validated with JHOVE

=cut

sub get_metadata_files {
    my $self = shift;
    my $book = $self->{groove_book};
    return $book->get_all_images();
}

=item get_utf8_files

Get all files that should be valid UTF-8

=cut

sub get_utf8_files {
    my $self = shift;
    my $book = $self->{groove_book};
    return [( @{ $book->get_all_ocr() }, @{ $book->get_all_hocr() })]; 
}

=item get_marc_xml

Returns an XML::LibXML node with the MARCXML

=cut

sub get_marc_xml {
    my $self = shift;
    my $book = $self->{groove_book};

    my $marcxml_string = $book->get_marcxml();

    my $marcxml_doc;

    my $mets_xc = $self->get_source_mets_xpc();
    my $mdsec_nodes = $mets_xc->find(
        q(//mets:dmdSec/mets:mdWrap[@MDTYPE="MARC"]/mets:xmlData));

    if ( $mdsec_nodes->size() ) {
        warn("Multiple MARC mdsecs found") if ( $mdsec_nodes->size() > 1 );
	my $node = $mdsec_nodes->get_node(0)->firstChild();
	# ignore any whitespace, etc.
	while($node->nodeType() != XML_ELEMENT_NODE) {
	    $node = $node->nextSibling();
	}
	return $node if defined $node;
    } 

    # no metadata found, or metadata node didn't contain anything
    croak("Could not find MARCXML in source METS");

}

=item get_repository_mets_path

Returns the full path where the METS file for this object 
would be, if this object was in the repository.

=cut

sub get_repository_mets_path {
    my $self = shift;
    my $book = $self->{groove_book};

    my $repos_symlink = $book->get_repository_symlink();

    return unless (-l $repos_symlink);

    my $mets_in_repository_file = sprintf("%s/%s.mets.xml",
	$repos_symlink,
	$book->get_pt_objid());

    return unless (-f $mets_in_repository_file);
    return $mets_in_repository_file;
}

=item get_repository_mets_xpc

Returns an XML::LibXML::XPathContext with namespaces set up 
and the context node positioned at the document root of the repository METS, if
the object is already in the repository. Returns false if the object is not
already in the repository.

=cut

sub get_repository_mets_xpc  {
    my $self = shift;
    my $book = $self->{groove_book};

    my $mets_in_repository_file = $self->get_repository_mets_path();
    return if not defined $mets_in_repository_file;

    my $xpc;

    eval {
	my $parser = XML::LibXML->new();
	my $doc    = $parser->parse_file($mets_in_repository_file);
	$xpc = XML::LibXML::XPathContext->new($doc);
	register_namespaces($xpc);
    };

    if ($@) {
	croak("Could not read METS file $mets_in_repository_file: $@");
    }
    return $xpc;

}

=item get_filecount

Returns the total number of content files

=cut

sub get_file_count {

    my $self = shift;
    return scalar(@{$self->get_all_content_files()});
}

=item get_page_count

Returns the number of pages in the volume as determined by the number of
images.

=cut

sub get_page_count {
    my $self = shift;
    return scalar(@{$self->{groove_book}->get_all_images()});
}

=item get_files_by_page

Returns a data structure listing what files belong to each file group in
physical page, e.g.:

{ '0001' => { txt => ['0001.txt'], 
	      img => ['0001.jp2'] },
  '0002' => { txt => ['0002.txt'],
	      img => ['0002.tif'] },
  '0003' => { txt => ['0003.txt'],
	      img => ['0003.jp2','0003.tif'] }
  };

=cut

sub get_file_groups_by_page {
    my $self = shift;
    my $filegroups      = $self->get_file_groups();
    my $files           = {};

    # First determine what files belong to each sequence number
    while ( my ( $filegroup_name, $filegroup ) =
	each( %{ $filegroups } ) )
    {
	foreach my $file ( @{$filegroup->get_filenames()} ) {
	    if ( $file =~ /(\d+)\.(\w+)$/ ) {
		my $sequence_number = $1;
		if(not defined $files->{$sequence_number}{$filegroup_name}) {
		    $files->{$sequence_number}{$filegroup_name} = [$file];
		} else {
		    push(@{ $files->{$sequence_number}{$filegroup_name} }, $file);
		}
	    }
	    else {
		$self->_set_error( "BadField", field => 'sequence_number', file => $file);
	    }
	}
    }

    return $files;

}

=item get_alt_record_id

Returns the altrecordid for the volume, if there is one.

=cut

sub get_alt_record_id {
    my $self = shift;

    return $self->{groove_book}->get_altRecordID_ID();

}

=item record_premis_event($eventtype,  
					date => $date,
					eventid => $eventid)

Records a PREMIS event that happens to the volume. Optionally, a PREMIS::Outcome object
and an event ID can be passed. If no event ID is passed, a default ID will be generated
automatically from the event type. If no date (in any format parseable by MySQL) is given,
the current date will be used. If the PREMIS event has already been recorded in the 
database, the date and outcome will be updated.

=cut

sub record_premis_event {
    my $self = shift;
    my $eventtype = shift;
    croak("Must provide an event type") unless $eventtype;

    my %params = @_;

    my $date = $params{date} or $self->_get_current_date();
    my $outcome_xml = $params{outcome}->as_node()->toString() if defined $params{outcome};

    my $db = GROOVE::DBTools->new();
    my $dbh = $db->get_dbh();

    my $set_premis_sth = $dbh->prepare("REPLACE INTO premis_events_new (namespace, barcode, eventtype_id, outcome, date) VALUES
	(?, ?, ?, ?, ?)");

    $set_premis_sth->execute($self->get_namespace(),$self->get_objid(),$eventtype,$outcome_xml,$date);

}

=item get_event_info( $eventtype )

Returns the date and outcome for the given event type for this volume.

=cut

sub get_event_info {
    my $self = shift;
    my $eventtype = shift;

    my $db = GROOVE::DBTools->new();
    my $dbh = $db->get_dbh();

    # TODO: move to replacement for DBTools
    my $event_sql = "SELECT date,outcome FROM premis_events_new where namespace = ? and barcode = ? and eventtype_id = ?";

    my $event_sth = $dbh->prepare($event_sql);
    my @params = ($self->get_namespace(),$self->get_objid(),$eventtype);

    my @events = ();

    $event_sth->execute(@params);
    # Should only be one event of each event type - enforced by primary key in DB
    if (my ($date, $outcome) = $event_sth->fetchrow_array()) {
	return ($date, $outcome);
    } else {
	return;
    }
}

=item _get_current_date

Returns the current date and time in a format parseable by MySQL

=cut

sub _get_current_date {

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

=item get_zip

Returns the name of the zipfile for this volume, if it exists

=cut

sub get_zip {
    my $self = shift;
    my $book = $self->{groove_book};
    return $book->get_zip();
}

=item get_page_data(file)

Returns a reference to a hash:

    { orderlabel => page number
      label => page tags }

for the page containing the given file.

If there is no detected page number or page tags for the given page,
the corresponding entry in the hash will not exist.

=cut

sub get_page_data {
    my $self = shift;
    my $file = shift;

    if(not defined $self->{'did_page_mapping'}) {
	$self->record_premis_event('page_feature_mapping');
	$self->{'did_page_mapping'} = 1;
    }
    (my $seqnum) = ($file =~ /(\d+)/);
    croak("Can't extract sequence number from file $file") unless $seqnum;
    my $pagedata = {};

    my $tags =  $self->{groove_book}->get_tags($seqnum);
    my $pagenum = $self->{groove_book}->get_detected_pagenum($seqnum);

    $pagedata->{'orderlabel'} = $pagenum if defined $pagenum;
    $pagedata->{'label'} = $tags if defined $tags;

    return $pagedata;
}

=item get_detected_pagenum(file)

Returns the detected page number for the page containing a given file, if there is one

=cut

sub get_page_number {
    my $self = shift;
    my $file = shift;

    my $seqnum = ($file =~ /(\d+)/);

    return $self->{groove_book}->get_detected_pagenum($seqnum);
}

=item get_mets_path

Returns the path to the METS file for this object

=cut

sub get_mets_path {
    my $self = shift;

    my $staging_path = $self->get_staging_directory();
    my $objid = $self->get_objid();
    my $mets_path = "$staging_path/$objid.mets.xml";

    return $mets_path;
}

1;



__END__;
