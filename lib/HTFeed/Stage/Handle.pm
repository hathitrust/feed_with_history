package HTFeed::Stage::Handle;

use warnings;
use strict;

use base qw(HTFeed::Stage);
use HTFeed::Config qw(get_config);
use HDL::Handle;
use DBI;

use Log::Log4perl qw(get_logger);
my $logger = get_logger(__PACKAGE__);

sub run{
    my $self = shift;

    my $volume = $self->{volume};
    my $identifier = $volume->get_identifier();
        
    my $handle = HDL::Handle->new(
        handle_name => $volume->get_nspkg()->get('handle_prefix') . ".$identifier",
        url => get_config('repo_url_base') . $identifier,
        root_admin => get_config('handle'=>'root_admin'),
        local_admin => get_config('handle'=>'local_admin'),
    );


    ## TODO: replace this DB boilerplate with DB library
    my $datasource = get_config('handle'=>'database'=>'datasource');
    my $user = get_config('handle'=>'database'=>'username');
    my $passwd = get_config('handle'=>'database'=>'password');

    eval {
        my $dbh = DBI->connect($datasource, $user, $passwd);
        my $sth = $dbh->prepare($handle->to_SQL());
        $sth->execute();
    }
    if($@) {
	    $self->_set_error('OperationFailed', detail => $@);
    }
    
    $self->_set_done();
    return $self->succeeded();
}

1;

__END__
