package HTFeed::PackageType::DLXS;

#legacy DLPS content

use strict;
use warnings;
use base qw(HTFeed::PackageType);

our $identifier = 'dlxs';

our $config = {
	%{$HTFeed::PackageType::config},
	description => 'DLXS legacy content',
	volume_module => 'HTFeed::PackageType::DLXS::Volume',

	#Regular expression that distinguished valid files in the file package
	#TODO Determine correct file types
    valid_file_pattern => qr/^( 
		checksum\.md5 |
		pageview\.dat |
		\w+\.(xml) |
        DLXS_[\w,]+\.(xml) |
		\d{8}.(html|jp2|tif|txt)
		)/x,

	#Filegroup configuration
    filegroups => {
		image => {
	   		prefix => 'IMG',
	   		use => 'image',
	   		file_pattern => qr/\d{8}\.(jp2|tif)$/,
	   		required => 1,
	   		content => 1,
	   		jhove => 1,
	   		utf8 => 0
		},
        ocr => {
            prefix => 'OCR',
            use => 'ocr',
            file_pattern => qr/\d{8}\.txt$/,
            required => 1,
            content => 1,
            jhove => 0,
            utf8 => 1
        },
    },

	#what stage to run given the current state
	stage_map => {
        ready       => 'HTFeed::PackageType::DLXS::Fetch',
        fetched     => 'HTFeed::PackageType::DLXS::ImageRemediate',
        images_remediated    => 'HTFeed::PackageType::DLXS::OCRSplit',
        ocr_extracted => 'HTFeed::PackageType::DLXS::SourceMETS',
        src_metsed		=> 'HTFeed::VolumeValidator',
		validated	=> 'HTFeed::Stage::Pack',
		packed		=> 'HTFeed::METS',
        metsed		=> 'HTFeed::Stage::Handle',
        handled		=> 'HTFeed::Stage::Collate',
    },

    # What PREMIS events to include in the source METS file
    source_premis_events => [
        # capture - included manually
#        'file_rename',
#        'source_md5_fixity',
        'image_header_modification',
        'ocr_normalize',
        'page_md5_create',
        'source_mets_creation',
        'mets_validation',
    ],

    # What PREMIS event types  to extract from the source METS and include in the HT METS
    source_premis_events_extract => [
        'capture',
#        'file_rename',
        'image_header_modification',
        'ocr_normalize',
        'page_md5_create',
        'source_mets_creation',
    ],

    premis_events => [
        'page_md5_fixity',
        'package_validation',
        
#        'page_feature_mapping', TODO
        'zip_compression',
        'zip_md5_create',
        'ingestion',
    ],

    # Overrides for the basic PREMIS event configuration
    premis_overrides => {
        'ocr_normalize' =>
          { detail => 'Split OCR into one plain text OCR file per page', }
    },

    source_mets_file => qr/^DLXS_[\w,]+\.xml$/,

};
