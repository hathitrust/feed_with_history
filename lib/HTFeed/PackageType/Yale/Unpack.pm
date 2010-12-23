package HTFeed::PackageType::Yale::Unpack;

use warnings;
use strict;

use base qw(HTFeed::Stage::Unpack);
use HTFeed::Config qw(get_config);

use Log::Log4perl qw(get_logger);
my $logger = get_logger(__PACKAGE__);

sub run{
    my $self = shift;
    my $volume = $self->{volume};

    my $download_dir = $volume->get_download_directory();
    my $objid = $volume->get_objid();

    my $file = sprintf('%s/%s.zip',$download_dir,$objid);
    $self->unzip_file($file,$volume->get_preingest_directory());

    $self->_set_done();
    return $self->succeeded();
}


1;

__END__
