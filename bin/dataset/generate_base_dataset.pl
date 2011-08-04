use warnings;
use strict;

use FindBin;
use lib "$FindBin::Bin/../../lib";

use HTFeed::Log { root_logger => 'INFO, dbi' };
use HTFeed::StagingSetup;
use HTFeed::Version;

use HTFeed::Dataset;
use HTFeed::Dataset::RightsDB;
use HTFeed::Volume;
use HTFeed::Config;

use Getopt::Long;

my $pid = $$;

# get volume list 
my $volumes = get_volumes(
    source => 'text',
    attributes => 'pd_us',
);

# wipe staging directories
HTFeed::StagingSetup::make_stage(1);


my $kids = 0;
my $max_kids = get_config('dataset'=>'threads');

foreach (my ($ns,$id) = @{$volumes}){
    
    eval{
        my $volume = HTFeed::Volume->new(
            objid       => $id,
            namespace   => $ns,
            packagetype => 'ht',
        );
    };
    if($@){
        # bad barcode
        next;
    }
    
    # Fork iff $max_kids != 0
    if($max_kids){
        spawn_volume_adder($volume);
    }
    else{
        # not forking
        add_volume($volume);
    }
}
while($kids){
    wait();
    $kids--;
}

sub spawn_volume_adder{
    my $volume = shift;
    
    # wait until we have a spare thread
    if($kids >= $max_kids){
        wait();
        $kids--;
    }
    
    my $pid = fork();

    if ($pid){
        # parent
        $kids++;
    }
    elsif (defined $pid){
        add_volume($volume);
        exit(0);
    }
    else {
        die "Couldn't fork: $!";
    }
}

sub add_volume{
    my $volume = shift;
    eval{
        HTFeed::Dataset::add_volume($volume);        
    };
    if($@){
        # record error
        get_logger('HTFeed::Dataset')->error( 'UnexpectedError', objid => $volume->get_objid, namespace => $volume->get_namespace, detail => $@ );
    }
}

END{
    HTFeed::StagingSetup::clear_stage()
        if ($$ eq $pid);
}
