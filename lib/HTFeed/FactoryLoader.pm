package HTFeed::FactoryLoader;

use warnings;
use strict;
use File::Basename;
use File::Find;
use Carp;

=head1 NAME

HTFeed::FactoryLoader

=head1 DESCRIPTION

	Common base stuff for namespace & packagetype

=cut

# hash of allowed config variables
our %subclass_map;

=item import()

 Load all subclasses

=cut

sub import {

    no strict 'refs';
    my $class = shift;

    # If called as use HTFeed::FactoryLoader qw(load_subclasses)
    if(@_ and $_[0] eq 'load_subclasses') {

        my $caller = caller();
        # determine the subdirectory to find plugins in
        my $module_path = $caller;
        $module_path =~ s/::/\//g;
        my $relative_path = $module_path;
        $module_path = $INC{$module_path . ".pm"} ;
        $module_path =~ s/.pm$//;

        # load the base class's identifier
        my $subclass_identifier = ${"${caller}::identifier"};
        die("$caller missing identifier")
            unless defined $subclass_identifier;
        $subclass_map{$caller}{$subclass_identifier} = $caller;

        # run callback for when package was loaded, if it exists
        if(eval "${caller}->can('on_factory_load')") {
            eval "${caller}->on_factory_load()";
            if($@) { die $@ };
        }

        # find the stuff that can be loaded
        foreach my $file (glob("$module_path/*.pm")) {
            if($file =~ qr(^$module_path/([^.]*)\.pm$) and -f $file) {                        
                my $id = lc($1);
                # map to %INC key/val
                $subclass_map{$caller}{$id} = "$relative_path/$1.pm";
            }

        }
    }

}

=item get_identifier()

 Get subclass identifier

=cut

sub get_identifier {
    no strict 'refs';
    my $self = shift;
    my $class = ref($self);
    my $subclass_identifier = ${"${class}::identifier"};
    return $subclass_identifier;
}

=item new()

 Must bless into subclass...

=cut

sub new {
    my $class      = shift;
    my $identifier = shift;

    my $inc_key = $subclass_map{$class}{$identifier};
    croak("Unknown subclass identifier $identifier") unless $inc_key;
    my $subclass = $inc_key;
    $subclass =~ s|/|::|g;
    $subclass =~ s/\.pm$//;

    if(not defined $INC{$inc_key}) {
        require "$inc_key";
        # run callback for when package was loaded, if it exists
        if(eval "$subclass->can('on_factory_load')") {
            eval "$subclass->on_factory_load()";
            if($@) { die $@ };
        }
    }

    return bless {}, $subclass;
}

1;

__END__

=pod

    INSERT_UNIVERSITY_OF_MICHIGAN_COPYRIGHT_INFO_HERE

=cut
