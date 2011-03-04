package HTFeed::Volume;

use warnings;
use strict;
use Carp;
use Log::Log4perl qw(get_logger);
use HTFeed::XMLNamespaces qw(register_namespaces);
use HTFeed::Namespace;
use HTFeed::FileGroup;
use XML::LibXML;
use HTFeed::Config qw(get_config);
use HTFeed::DBTools;
use Time::localtime;
use File::Pairtree;
use Data::UUID;
use File::Path qw(remove_tree);

our $logger = get_logger(__PACKAGE__);

# The namespace UUID for HathiTrust
use constant HT_UUID => '09A5DAD6-3484-11E0-9D45-077BD5215A96';

sub new {
    my $package = shift;

    my $self = {
        objid     => undef,
        namespace => undef,
        packagetype => undef,
        uuidgen => new Data::UUID,
        @_,

        #		files			=> [],
        #		dir			=> undef,
        #		mets_name		=> undef,
        #		mets_xml		=> undef,
    };

    $self->{nspkg} = HTFeed::Namespace->new($self->{namespace},$self->{packagetype});

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

=item get_packagetype

Returns the packagetype of the volume.

=cut

sub get_packagetype {
    my $self = shift;
    return $self->{packagetype};
}

=item get_pt_objid

Returns the pairtreeized ID of the volume

=cut

sub get_pt_objid {
    my $self = shift;
    return s2ppchars($self->{objid});
}

=item get_file_groups 

Returns a hash of HTFeed::FileGroup objects containing info about the logical groups
of files in the objects. Configure through the filegroups package type setting.

=cut

sub get_file_groups {
    my $self = shift;

    if(not defined $self->{filegroups}) {
        my $filegroups = {}; 

        my $nspkg_filegroups = $self->{nspkg}->get('filegroups');
        while( my ($key,$val) = each (%{ $nspkg_filegroups })) {
            my $files = [];
            my $re = $val->{file_pattern} or die("Missing pattern for filegroup $key");
            foreach my $file ( @{ $self->get_all_directory_files() }) {
                push(@$files,$file) if $file =~ $re;
            }
            $filegroups->{$key} = new HTFeed::FileGroup($files,%$val);
        }
        $self->{filegroups} = $filegroups;
    }

    return $self->{filegroups};
}

=item get_all_directory_files

Returns a list of all files in the staging directory for the volume's AIP

=cut

sub get_all_directory_files {
    my $self = shift;

    if(not defined $self->{directory_files}) {
        $self->{directory_files} = [];
        my $stagedir = $self->get_staging_directory();
        opendir(my $dh,$stagedir) or croak("Can't opendir $stagedir: $!");
        foreach my $file (readdir $dh) {
            # ignore ., ..
            push(@{ $self->{directory_files} },$file) unless $file =~ /^\.+$/;
        }
        closedir($dh) or croak("Can't closedir $stagedir: $!");
        @{ $self->{directory_files} } = sort( @{ $self->{directory_files} } );
    }

    return $self->{directory_files};
}

=item get_staging_directory

Returns the staging directory for the volume's AIP
returns path to staging directory on disk if $flag

=cut

sub get_staging_directory {
    my $self = shift;
    my $flag = shift;
    my $pt_objid = $self->get_pt_objid();
    return get_config('staging'=>'disk'=>'ingest') . q(/) . $pt_objid if $flag;
    return get_config('staging'=>'ingest') . q(/) . $pt_objid;
}

=item mk_staging_directory

makes staging directory, if $flag, creates it on disk rather than ram and symlinks to ram
returns staging directory

=synopsis
mk_staging_dir($flag)
=cut

sub mk_staging_directory{
    my $self = shift;
    my $flag = shift;
    
    my $stage_dir = $self->get_staging_directory();
    
    if($flag){
        my $disk_stage_dir = $self->get_staging_directory(1);
        mkdir($disk_stage_dir) or croak("Can't mkdir $disk_stage_dir: $!");
        symlink($disk_stage_dir,$stage_dir) or croak("Can't symlink $disk_stage_dir,$stage_dir: $!");
    }
    else{
        mkdir($stage_dir) or croak("Can't mkdir $stage_dir: $!");
    }

    return $stage_dir;
}


=item get_download_directory

Returns the directory the volume's SIP should be downloaded to

=cut

sub get_download_directory {
    return get_config('staging'=>'download');
}

=item get_all_content_files

Returns a list of all files that will be validated.

=cut

sub get_all_content_files {
    my $self = shift;

    if(not defined $self->{content_files}) {
        foreach my $filegroup (values(%{ $self->get_file_groups()})) {
            push(@{ $self->{content_files} },@{ $filegroup->get_filenames() }) if $filegroup->{content};
        }
    }

    return $self->{content_files};
}

=item get_checksums

Returns a hash of precomputed checksums for files in the package's AIP where
the keys are the filenames and the values are the MD5 checksums.

=cut

sub get_checksums {
    my $self = shift;

    if ( not defined $self->{checksums} ) {

        my $checksums = {};
        # try to extract from source METS
        my $xpc = $self->get_source_mets_xpc();
        foreach my $node ( $xpc->findnodes('//mets:file') ) {
            my $checksum = $xpc->findvalue( './@CHECKSUM', $node );
            my $filename =
            $xpc->findvalue( './mets:FLocat/@xlink:href', $node );
            $checksums->{$filename} = $checksum;
        }

        $self->{checksums} = $checksums;
    }

    return $self->{checksums};
}

=item get_source_mets_file

Returns the name of the source METS file

TODO: support more general creation, substitution of templates in METS file

=cut

sub get_source_mets_file {
    my $self = shift;
    if(not defined $self->{source_mets_file}) {
        my $src_mets_re = $self->{nspkg}->get('source_mets_file');

        foreach my $file ( @{ $self->get_all_directory_files() }) {
            if($file =~ $src_mets_re) {
                if(not defined $self->{source_mets_file}) {
                    $self->{source_mets_file} = $file;
                } else {
                    croak("Two or more files match source METS RE $src_mets_re: $self->{source_mets_file} and $file");
                }
            }
        }
    }

    return $self->{source_mets_file};
}

=item get_source_mets_xpc

Returns an XML::LibXML::XPathContext with namespaces set up 
and the context node positioned at the document root of the source METS.

=cut

sub get_source_mets_xpc {
    my $self = shift;

    if(not defined $self->{source_mets_xpc}) {
        my $mets = $self->get_source_mets_file();
        my $path = $self->get_staging_directory();

        die("Missing METS file") unless defined $mets and defined $path;
        $self->{source_mets_xpc} = $self->_parse_xpc("$path/$mets");

    }
    return $self->{source_mets_xpc};

}

=item _parse_xpc

Returns an XML::LibXML::XPathContext with namespaces set up
and the context node positioned at the document root of the given XML file.

=cut

sub _parse_xpc {
    my $self = shift;
    my $file = shift;
    my $xpc;
    eval {
        die "Missing file $file" unless -e "$file";
        my $parser = XML::LibXML->new();
        my $doc    = $parser->parse_file("$file");
        $xpc = XML::LibXML::XPathContext->new($doc);
        register_namespaces($xpc);
    };

    if ($@) {
        croak("-ERR- Could not read XML file $file: $@");
    } else {
        return $xpc;
    }
}

=item get_repos_mets_xpc

Returns an XML::LibXML::XPathContext with namespaces set up 
and the context node positioned at the document root of the source METS.

=cut

sub get_repos_mets_xpc {
    my $self = shift;

    if (not defined $self->{repos_mets_xpc}) {

        my $mets = $self->get_repository_mets_path();
        return unless defined $mets;

        $self->{repos_mets_xpc} = $self->_parse_xpc($mets);
    }

    return $self->{repos_mets_xpc};

}

=item get_nspkg

Returns the HTFeed::Namespace object that provides namespace & package type-
specific configuration information.

=cut

sub get_nspkg{
    my $self = shift;
    return $self->{nspkg};
}

=item get_stages($start_state)

Returns array ref containing a list of stage this Volume needs for a full ingest process,
starting from the given start state, or 'ready' if none is specified.

=cut

sub get_stages{
    my $self = shift;
    my $stage_map = $self->get_nspkg()->get('stage_map');
    my $stage_name = shift;
    $stage_name = 'ready' if not defined $stage_name;
    my $stages = [];
    my $stage_class;

    while ($stage_class = $stage_map->{$stage_name}){
        push ( @{ $stages }, $stage_class );
        $stage_name = eval "$stage_class->get_stage_info('success_state')";
    }

    return $stages;
}

=item get_jhove_files

Get all files that will need to have their metadata validated with JHOVE

=cut

sub get_jhove_files {
    my $self = shift;
    if(not defined $self->{jhove_files}) {
        foreach my $filegroup (values(%{ $self->get_file_groups()})) {
            push(@{ $self->{jhove_files} },@{ $filegroup->get_filenames() }) if $filegroup->{jhove};
        }
    }

    return $self->{jhove_files};
}

=item get_utf8_files

Get all files that should be valid UTF-8

=cut

sub get_utf8_files {
    my $self = shift;
    if(not defined $self->{utf8_files}) {
        foreach my $filegroup (values(%{ $self->get_file_groups()})) {
            push(@{ $self->{utf8_files} },@{ $filegroup->get_filenames() }) if $filegroup->{utf8};
        }
    }

    return $self->{utf8_files};
}

=item get_marc_xml

Returns an XML::LibXML node with the MARCXML

=cut

sub get_marc_xml {
    my $self = shift;
    my $marcxml_doc;

    my $mets_xc = $self->get_source_mets_xpc();
    my $mdsec_nodes = $mets_xc->find(
        q(//mets:dmdSec/mets:mdWrap[@MDTYPE="MARC"]/mets:xmlData));

    if ( $mdsec_nodes->size() ) {
        $logger->warn("Multiple MARC mdsecs found") if ( $mdsec_nodes->size() > 1 );
        my $node = $mdsec_nodes->get_node(0)->firstChild();
        # ignore any whitespace, etc.
        while($node->nodeType() != XML_ELEMENT_NODE) {
            $node = $node->nextSibling();
        }
        if(defined $node) {
            # check & remediate MARC
            my $marc_xc = new XML::LibXML::XPathContext($node);
            register_namespaces($marc_xc);
            HTFeed::METS::_remediate_marc($self,$marc_xc);
            return $node;
        }
    } 

    # no metadata found, or metadata node didn't contain anything
    croak("Could not find MARCXML in source METS");

}

=item get_repository_symlink

Returns the path to the repository symlink for the object.
(or the directory if the repository does not use symlinks)

=cut

sub get_repository_symlink {
    my $self = shift;


    if(not defined $self->{repository_symlink}) {
        my $link_dir = get_config("repository","link_dir");
        my $namespace = $self->get_namespace();

        my $objid = $self->get_objid();

        my $pairtree_path = id2ppath($objid);

        my $pt_objid = $self->get_pt_objid();

        my $symlink = "$link_dir/$namespace/$pairtree_path/$pt_objid";
        $self->{repository_symlink} = $symlink;
    }

    return $self->{repository_symlink};
}

=item get_repository_mets_path

Returns the full path where the METS file for this object 
would be, if this object was in the repository.

=cut

sub get_repository_mets_path {
    my $self = shift;

    my $repos_symlink = $self->get_repository_symlink();

    return unless (-l $repos_symlink or -d $repos_symlink);

    my $mets_in_repository_file = sprintf("%s/%s.mets.xml",
        $repos_symlink,
        $self->get_pt_objid());

    return unless (-f $mets_in_repository_file);
    return $mets_in_repository_file;
}

=item get_repository_zip_path

Returns the full path where the zip file for this object 
would be, if this object was in the repository.

=cut

sub get_repository_zip_path {
    my $self = shift;

    my $repos_symlink = $self->get_repository_symlink();

    return unless (-l $repos_symlink or -d $repos_symlink);

    my $zip_in_repository_file = sprintf("%s/%s.zip",
        $repos_symlink,
        $self->get_pt_objid());

    return unless (-f $zip_in_repository_file);
    return $zip_in_repository_file;
}

=item get_repository_mets_xpc

Returns an XML::LibXML::XPathContext with namespaces set up 
and the context node positioned at the document root of the repository METS, if
the object is already in the repository. Returns false if the object is not
already in the repository.

=cut

sub get_repository_mets_xpc  {
    my $self = shift;

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
    my $image_group = $self->get_file_groups()->{image};
    croak("Page count requested for object with no image filegroup") unless defined $image_group;
    return scalar(@{ $image_group->get_filenames() });
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
                croak("Can't get sequence number for $file");
            }
        }
    }

    return $files;

}

# TODO: altRecordID

=item record_premis_event($eventtype_id,  
                    date => $date,
                    outcome => $outcome)

Records a PREMIS event that happens to the volume. Optionally, a PREMIS::Outcome object
can be passed. If no date (in any format parseable by MySQL) is given,
the current date will be used. If the PREMIS event has already been recorded in the 
database, the date and outcome will be updated.

The eventtype_id refers to the event definitions in the application configuration file, not
the PREMIS eventType (which is configured in the event definition)

=cut

sub record_premis_event {
    my $self = shift;
    my $eventcode = shift;
    my $eventconfig = $self->get_nspkg()->get_event_configuration($eventcode);
    my $eventtype = $eventconfig->{'type'};
    croak("Event code / type not found") unless $eventtype;

    my %params = @_;

    my $date = ($params{date} or $self->_get_current_date());
    my $outcome_xml = $params{outcome}->to_node()->toString() if defined $params{outcome};

    my $dbh = HTFeed::DBTools::get_dbh();

    my $uuid = $self->make_premis_uuid($eventtype,$date); 

    my $set_premis_sth = $dbh->prepare("REPLACE INTO premis_events (namespace, id, eventid, eventtype_id, outcome, date) VALUES
        (?, ?, ?, ?, ?, ?)");

    $set_premis_sth->execute($self->get_namespace(),$self->get_objid(),$uuid,$eventcode,$outcome_xml,$date);

}

=item make_premis_uuid($eventtype,$date)

Returns a UUID for a PREMIS event for this object of type $eventtype occurring
at time $date.  There is no required format for the date, but it should be
consistent to get stable UUIDs for events occurring at the same time.

=cut

sub make_premis_uuid {
    my $self = shift;
    my $eventtype = shift;
    my $date = shift;
    my $tohash = join("-",$self->get_namespace(),$self->get_objid(),$eventtype,$date);
    my $uuid = $self->{uuidgen}->create_from_name_str(HT_UUID,$tohash);
    return $uuid;
}

=item get_event_info( $eventtype )

Returns the date and outcome for the given event type for this volume.

=cut

sub get_event_info {
    my $self = shift;
    my $eventtype = shift;

    my $dbh = HTFeed::DBTools::get_dbh();

    my $event_sql = "SELECT eventid,date,outcome FROM premis_events where namespace = ? and id = ? and eventtype_id = ?";

    my $event_sth = $dbh->prepare($event_sql);
    my @params = ($self->get_namespace(),$self->get_objid(),$eventtype);

    my @events = ();

    $event_sth->execute(@params);
    # Should only be one event of each event type - enforced by primary key in DB
    if (my ($eventid, $date, $outcome) = $event_sth->fetchrow_array()) {
        # replace space separating date from time with 'T'
        $date =~ s/ /T/g;
        my $outcome_node = undef;
        if($outcome) {
            $outcome_node = XML::LibXML->new()->parse_string($outcome);
            $outcome_node = $outcome_node->documentElement();
        }
        return ($eventid, $date, $outcome_node);
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

=item get_zip_path

Returns the path to the zip archive to construct for this object.

If called in an array context, returns an array containing 
the staging path and the name of the zip file. If called in a
scalar context, returns the path to the zip file.

=cut

sub get_zip_path {
    my $self = shift;
    my $staging_path = get_config('staging'=>'ingest');
    my $pt_objid = $self->get_pt_objid();

    if(wantarray) {
        return ($staging_path,"$pt_objid.zip");
    } else {
        return "$staging_path/$pt_objid.zip";
    }

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
    return undef;
}

=item get_mets_path

Returns the path to the METS file to construct for this object

=cut

sub get_mets_path {
    my $self = shift;

    my $staging_path = get_config('staging'=>'ingest');
    my $pt_objid = $self->get_pt_objid();
    my $mets_path = "$staging_path/$pt_objid.mets.xml";

    return $mets_path;
}

=item get_SIP_filename

Returns the SIP's filename

=cut

sub get_SIP_filename {
    my $self = shift;
    my $objid = $self->{objid};
    my $pattern = $self->{nspkg}->get('SIP_filename_pattern');
    return sprintf($pattern,$objid);
}

sub clean_all {
    my $self = shift;
    $logger->warn("Removing " . $self->get_staging_directory());
    remove_tree $self->get_staging_directory();
    unlink($self->get_mets_path());
    $logger->warn("Removing " . $self->get_mets_path());
    unlink($self->get_zip_path());
    $logger->warn("Removing " . $self->get_zip_path());
}


=item get_preingest_directory

Returns the directory where the raw submitted object is staged. 
Returns undef by default; package type subclasses must define.

should use get_config('staging'=>'preingest') as a base dir
or use get_config('staging'=>'disk'=>'preingest') if $flag

=cut

sub get_preingest_directory {
    return;
}

=item get_download_location

Returns the file or path (if the SIP consists of multiple files) to download
the volume to. This file or path will be removed when the volume is successfully
ingested.

=cut 
sub get_download_location {
    my $self = shift;
    my $staging_dir = $self->get_download_directory();
    return "$staging_dir/" . $self->get_SIP_filename();
    return;
}


=item mk_preingest_directory

makes preingest directory, if $flag, creates it on disk rather than ram and symlinks to ram.
returns preingest directory (or the link if $flag)

=synopsis
mk_preingest_directory($flag)
=cut

sub mk_preingest_directory{
    my $self = shift;
    my $flag = shift;
    
    my $stage_dir = $self->get_preingest_directory();
    
    if($flag){
        my $disk_stage_dir = $self->get_preingest_directory(1);
        mkdir($disk_stage_dir) or croak("Can't mkdir $disk_stage_dir: $!");
        symlink($disk_stage_dir,$stage_dir) or croak("Can't symlink $disk_stage_dir,$stage_dir: $!");
    }
    else{
        mkdir($stage_dir) or croak("Can't mkdir $stage_dir: $!");
    }

    return $stage_dir;
}

=item clear_premis_events

Deletes the PREMIS events for this volume. Typically used when the volume has been collated
and there is no longer a need to retain the PREMIS events in the database.

=cut

sub clear_premis_events {
    my $self = shift;
	my $volume = $self->{volume};

    my $ns = $volume->get_namespace();
    my $objid = $self->get_objid();
    my $sth = HTFeed::DBTools::get_dbh()->prepare("DELETE FROM premis_events WHERE namespace = ? and id = ?");
    $sth->execute($ns,$objid);

}

1;



__END__;
