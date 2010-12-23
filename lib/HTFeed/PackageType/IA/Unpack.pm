package HTFeed::PackageType::IA::Unpack;

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
    my $preingest_dir = $volume->get_preingest_directory();
    my $objid = $volume->get_objid();
    my $ia_id = $volume->get_ia_id();


    my $file = sprintf('%s/%s_jp2.zip',$download_dir,$ia_id);
    $self->unzip_file($file,$preingest_dir);

    $self->_set_done();
    return $self->succeeded();
}


1;

__END__
