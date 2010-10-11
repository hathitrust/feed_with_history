package HTFeed::Namespace;

use warnings;
use strict;
use Algorithm::LUHN;
use Carp;
use HTFeed::FactoryLoader 'load_subclasses';
use HTFeed::PackageType;
use HTFeed::Config qw(get_config);

use base qw(HTFeed::FactoryLoader);

sub new {
    my $class = shift;
    my $namespace_id = shift;
    my $packagetype = shift;
    my $self = $class->SUPER::new($namespace_id);
    if(defined $packagetype) {
	# Can accept either a already-constructed HTFeed::PackageType or the package type identifier.
	if(!ref($packagetype)) {
	    $packagetype = new HTFeed::PackageType($packagetype);
	}
	$self->{'packagetype'} = $packagetype;
    } else {
	croak("Missing packagetype for namespace $namespace_id"); 
    }

    return $self;
}


=item get($config)

Returns a given configuration variable. First searches the packagetype override
for a given configuration variable. If not found there, uses the namespace base
configuration, and if not there, the package type base configuration.

=cut

sub get {
    my $self = shift;
    my $config_var = shift;

    my $class = ref($self);

    no strict 'refs';

    my $packagetype_id = $self->{'packagetype'}->get_identifier();
    my $ns_pkgtype_override = ${"${class}::packagetype_overrides"}->{$packagetype_id};
    my $ns_config = ${"${class}::config"};

    if (defined $ns_pkgtype_override and defined $ns_pkgtype_override->{$config_var}) {
	return $ns_pkgtype_override->{$config_var};
    } elsif (defined $ns_config->{$config_var}) {
	return $ns_config->{$config_var};
    } elsif (defined $self->{'packagetype'}) {
	my $pkgtype_var = eval { $self->{'packagetype'}->get($config_var);
	};
	if($@) {
	    croak("Can't find namespace/packagetype configuration variable $config_var");
	} else {
	    return $pkgtype_var;
	}
    }

}

=item get_validation_overrides($module)

Collects the validation overrides from the current namespace and package type
for the given validation module (e.g.  HTFeed::ModuleValidator::JPEG2000_hul) 

=cut

sub get_validation_overrides {
    my $self = shift;
    my $module = shift;

    my $class = ref($self);
    no strict 'refs';
    my $overrides = {};
    my $packagetype_id = $self->{'packagetype'}->get_identifier();
    my $ns_pkgtype_override = ${"${class}::packagetype_overrides"}->{$packagetype_id};
    my $ns_config = ${"${class}::config"};
    foreach my $override_source (
	$self->{'packagetype'}->get('validation'), # lowest priority - packagetype-specific
	$ns_config->{'validation'}, # then namespace-specific
	$ns_pkgtype_override->{'validation'}) { # then namespace/packagetype-pair- specific
	if(defined $override_source
		and exists $override_source->{$module}) {
	    while(my ($k,$v) = each ( %{ $override_source->{$module} })) {
		$overrides->{$k} = $v;
	    }
	}
    }

    return $overrides;

}

# PREMIS events

=item get_event_description($eventtype)

Collects the info for a given PREMIS event type, as specified in the global configuration
and optionally overridden in package type and namespace configuration.

=cut

sub get_event_configuration {
    my $self = shift;
    my $eventtype = shift;

    my $info = {};

    my $eventtype_global = get_config('premis',$eventtype);
    # Did he sell beans? Lord, no..
    #
    # Did he sell eggs? Lord, no..
    #
    # But he couldn't and he wouldn't and he shouldn't, so he stapled it down.
}

# UTILITIES FOR SUBCLASSES

=item luhn_is_valid($systemid,$barcode)

Returns true if the given barcode is valid for a book according to the common
'codabar mod 10' barcode scheme and has the given system ID.

=cut

sub luhn_is_valid {
    my $self = shift;
    my $itemtype_systemid = shift;
    my $barcode = shift;

    croak("Expected 5-digit item type + systemid") if $itemtype_systemid !~ /^\d{5}$/;
    return ($barcode =~ /^$itemtype_systemid\d{9}$/ and Algorithm::LUHN::is_valid($barcode));
    
}

1;
__END__

=pod

This is the superclass for all namespaces. It provides a common interface to get configuration 
variables and overrides for namespace/package type combinations.

=head1 SYNOPSIS

use HTFeed::Namespace;

$namespace = new HTFeed::Namespace('mdp','google');
$grinid = $namespace->get('grinid');

=head1 AUTHOR

Aaron Elkiss, University of Michigan, aelkiss@umich.edu

=head1 COPYRIGHT

Copyright (c) 2010 University of Michigan. All rights reserved.  This program
is free software; you can redistribute it and/or modify it under the same terms
as Perl itself.

=cut
