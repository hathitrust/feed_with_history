#!/usr/bin/perl
package TestIA;

use strict;
use warnings;
use Setup;

#which need to be here?
use File::Temp ();
use File::Copy;
use HTFeed::Config qw(set_config);
use Getopt::Long;
use FindBin;
use HTFeed::Volume;
use HTFeed::Log {root_logger => 'TRACE, file'};
use YAML::XS ();
use base qw(Test::Class);
use Test::More;
use HTFeed::Volume;
use Test::Class;
use HTFeed::PackageType::IA::Download;

my $self = shift;
my $object = new Setup("path", "objid", "package_type", "namespace");
my $path = $object->getPath();
my $objid = $object->getObjid();
my $package_type = $object->getPkg();
my $namespace = $object->getNamespace();

#XXX for testing
print "path: $path\nobjid: $objid\npackage_type: $package_type\nnamespace: $namespace\n";

set_config($path,'staging'=>'ingest');

sub Volume : Test(setup) {
        my $volume = HTFeed::Volume->new(objid => $objid,namespace => $namespace,packagetype => $package_type);
        shift->{volume} = $volume;
}


sub Download : Test(1) {
        my $volume = shift->{volume};
        my $vol_val = HTFeed::PackageType::IA::Download->new(volume => $volume);
        $vol_val->run();
        ok($vol_val->succeeded(), "Download for $package_type $namespace $objid");
};

1;
