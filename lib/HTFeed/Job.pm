package HTFeed::Job;

#use Moose;
use Any::Moose;
use HTFeed::Volume;

has [qw(pkg_type namespace id)]         => (is => 'ro', isa => 'Str',     required => 1);
has 'status'                            => (is => 'ro', isa => 'Str',     required => 1, default => 'ready');
has 'callback'                          => (is => 'ro', isa => 'CodeRef', required => 1);
has 'failure_count'                     => (is => 'rw', isa => 'Str',     required => 1, default => 0);
has 'stage_class'                       => (is => 'ro', isa => 'Str',     init_arg => undef, lazy_build => 1);
has [qw(volume stage)]                  => (is => 'ro', isa => 'Object',  init_arg => undef, lazy_build => 1);

=item new

callback is a coderef to update status of job

must take args as follows:
callback($ns,$id,$status,[$release],[$fail])

=synopsis
HTFeed::Job->new($pkg_type, $namespace, $id, $status, $failure_count, \&callback)
HTFeed::Job->new(   pkg_type => $pkg_type,
                    namespace => $namespace,
                    id => $id,
                    [status => $status,] # defaults to ready
                    [failure_count => $failure_count,] # defaults to 0
                    callback => \&callback)
=cut

=item update

$job->update($status, [$fail]);

uses callback to update job status (usually in the queue db table, but the callback can do whatever you want)
note: status of this job DOES NOT change from what was defined on instantiation; jobs are not intended to be re-used

=synopsis

$job->update("punted",1);
$job->update("collated");

=cut
sub update{
    my $self = shift;

    my $fail = $self->stage->failed;
    my $new_status = $stage->get_stage_info('success_state');
    $new_status = $stage->get_stage_info('failure_state') if ($fail);

    ## TODO: make this a class global or see if it can be better accessed with YAML::Config, etc.
    ## i.e. put it somwhere else, but preferably somthing tidy
    my %release_states = map {$_ => 1} @{get_config('daemon'=>'release_states')};

    my $release = 0;
    $release = 1 if (defined $release_states{$new_status});
    
    &{$self->{callback}}($self->{namespace}, $self->{id}, $new_status, $release, $fail);
    
    return;
}

# this wraps the default constructor to allow non-hash-style args
around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;
    
    # exactly 6 args to construct w/o hash style args
    # 10-12 with hash style args
    if ( @_ == 6 ) {
        my ($pkg_type, $namespace, $id, $status, $failure_count, $callback) = @_;
        return $class->$orig(pkg_type => $pkg_type,
                             namespace => $namespace,
                             id => $id,
                             status => $status,
                             failure_count => $failure_count,
                             callback => $callback);
    }
    else {
        return $class->$orig(@_);
    }
};

sub _build_volume{
    my $self = shift;
    #warn "building volume";
    return HTFeed::Volume->new(
        objid       => $self->id,
        namespace   => $self->namespace,
        packagetype => $self->pkg_type,
    );
}

sub _build_stage_class{
    my $self = shift;

    my $class = $self->volume->next_stage($self->status);
    
    ## TODO: remove this hack once 'clean' branch is merged
    $class =~ s/\//::/g;
    return $class;
}

sub _build_stage{
    my $self = shift;
    
    my $class = $self->stage_class;
    my $volume = $self->volume;
    
    return eval "$class->new(volume => \$volume)";
}

=item runnable
returns 1 if status successfully maps to a stage in the volume's stage map, else false
=cut
sub runnable{
    my $self = shift;
    return unless $self->stage_class;
    return 1;
}

1;

__END__
