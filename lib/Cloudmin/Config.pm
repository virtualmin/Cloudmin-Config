package Cloudmin::Config;

# ABSTRACT: Configure a system for use by Cloudmin
use strict;
use warnings;
no warnings qw(once);    # We've got some globals that effect Webmin behavior
use 5.016_001;           # Version shipped with CentOS 7. Nothing older.
use Module::Load;
use Term::ANSIColor qw(:constants);
use Log::Log4perl qw(:easy);

# globals
our (%gconfig, %uconfig, %miniserv, %uminiserv);
our ($root_directory, $config_directory);
our ($trust_unknown_referers, $no_acl_check, $error_must_die, $file_cache);

sub new {
  my ($class, %args) = @_;
  my $self = {};

  $self->{bundle}  = $args{bundle};
  $self->{include} = $args{include};
  $self->{exclude} = $args{exclude};
  $self->{test}    = $args{test};
  $self->{log}     = $args{log} || "/root/cloudmin-install.log";

  return bless $self, $class;
}

# Gathered plugins are processed
sub run {
  my $self = shift;

  $| = 1;    # No line buffering.

  # TODO This should really just be "use Webmin::Core"
  $no_acl_check   = 1;
  $error_must_die = 1;

  # Initialize logger
  my $log_conf = qq(
  	log4perl.logger 		= INFO, FileApp
  	log4perl.appender.FileApp	= Log::Log4perl::Appender::File
    log4perl.appender.FileApp.utf8     = 1
  	log4perl.appender.FileApp.filename = $self->{log}
  	log4perl.appender.FileApp.layout   = PatternLayout
  	log4perl.appender.FileApp.layout.ConversionPattern = [%d] [%p] - %m%n
  	log4perl.appender.FileApp.mode	= append
  );
  Log::Log4perl->init(\$log_conf);
  my $log = Log::Log4perl->get_logger("cloudmin-config-system");
  $log->info("Starting init-system log...");

  my @plugins = $self->_gather_plugins();
  @plugins = $self->_order_plugins(@plugins);
  my $total = scalar @plugins;
  $log->info("Total plugins to be run: $total");
  for (@plugins) {
    my $pkg = "Cloudmin::Config::Plugin::$_";
    load $pkg || die "Loading Plugin failed: $_";
    my $plugin = $pkg->new(total => $total, bundle => $self->{bundle});
    $plugin->actions();
    if ($self->{test} && $plugin->can('tests')) {
      $plugin->tests();
    }
  }
  return 1;
}

# list_bundles
# Returns a list of the available configuration bundles.
sub list_bundles {
  my $self = shift;

  # Figure out our module home directory
  my $modpath = $INC{'Cloudmin/Config.pm'};
  use File::Basename;
  my $bundlepath = dirname($modpath) . '/Config';
  opendir(my $DIR, $bundlepath);
  my @bundles = grep(/\.pm$/, readdir($DIR));
  closedir($DIR);
  @bundles = grep { $_ ne 'Dummy.pm' && $_ ne 'Plugin.pm' } @bundles;
  for (@bundles) {s/\.pm$//}
  @bundles = sort(@bundles);
  return @bundles;
}

# list-plugins
# Returns a sorted list of the available plugins.
sub list_plugins {
  my $self = shift;

  # Figure out our module home directory
  require Cloudmin::Config::Plugin;
  my $modpath = $INC{'Cloudmin/Config/Plugin.pm'};
  use File::Basename;
  my $pluginpath = dirname($modpath) . '/Plugin';
  opendir(my $DIR, $pluginpath);
  my @plugins = grep(/\.pm$/, readdir($DIR));
  closedir($DIR);
  @plugins = grep { $_ ne 'Test.pm' && $_ ne 'Test2.pm' } @plugins;
  for (@plugins) {s/\.pm$//}
  @plugins = sort(@plugins);
  return @plugins;
}

# Merges the selected bundle, with any extra includes, and removes excludes
sub _gather_plugins {
  my $self = shift;
  my @plugins;

  # If bundle specified, load it up.
  if ($self->{bundle}) {
    my $pkg = "Cloudmin::Config::$self->{bundle}";
    load $pkg;
    my $bundle = $pkg->new();

    # Ask the bundle for a list of plugins
    @plugins = $bundle->plugins();
  }

  # Check with the command arguments
  if (ref($self->{include}) eq 'ARRAY' || ref($self->{include}) eq 'STRING') {
    for my $include ($self->{'include'}) {
      push(@plugins, $include)
        unless (map { grep(/^$include$/, @{$_}) } @plugins);
    }
  }

  # Check for excluded plugins
  my @noplugins = _flat($self->{'exclude'});
  if (@noplugins) {
    @plugins = _flat(@plugins);
    no warnings "uninitialized";
    @plugins = grep { my $noplugin = $_; !grep( /^$noplugin$/, @noplugins) } @plugins;
  }
  return @plugins;
}

# Take the gathered list of plugins and sort them to resolve deps
sub _order_plugins {
  my ($self, @plugins) = @_;
  my %plugin_details;    # Will hold an array of hashes containing name/depends
                         # Load up @plugin_details with name and dependency list
  if (ref($plugins[0]) eq 'ARRAY') {    # XXX Why is this so stupid?
    @plugins = map {@$_} @plugins;      # Flatten the array of refs into list.
  }
  for my $plugin_name (@plugins) {
    my $pkg = "Cloudmin::Config::Plugin::$plugin_name";
    load $pkg;
    my $plugin = $pkg->new();
    $plugin_details{$plugin->{'name'}} = $plugin->{'depends'} || [];
  }
  return _topo_sort(%plugin_details);
}

# Topological sort on dependencies
sub _topo_sort {
  my (%deps) = @_;

  my %ba;
  while (my ($before, $afters_aref) = each %deps) {
    unless (@{$afters_aref}) {
      $ba{$before} = {};
    }
    for my $after (@{$afters_aref}) {
      $ba{$before}{$after} = 1 if $before ne $after;
      $ba{$after} ||= {};
    }
  }
  my @rv;
  while (my @afters = sort grep { !%{$ba{$_}} } keys %ba) {
    push @rv, @afters;
    delete @ba{@afters};
    delete @{$_}{@afters} for values %ba;
  }

  return _uniq(@rv);
}

# uniq so we don't have to import List::MoreUtils
sub _uniq {
  my %seen;
  return grep { !$seen{$_}++ } @_;
}

# Flatten into plain list
sub _flat {
  return map {ref eq 'ARRAY' ? @$_ : $_} @_;
}

1;

__END__

=pod

=encoding utf8

=for html <a href="https://travis-ci.org/virtualmin/Cloudmin-Config">
<img src="https://travis-ci.org/virtualmin/Cloudmin-Config.svg?branch=master">
</a>&nbsp;
<a href='https://coveralls.io/github/virtualmin/Cloudmin-Config?branch=master'>
<img src='https://coveralls.io/repos/github/virtualmin/Cloudmin-Config/badge.svg?branch=master'
alt='Coverage Status' /></a>


=head1 NAME

Cloudmin::Config - A collection of plugins to initialize the configuration
of services that Cloudmin manages, and a command line tool called
config-system to run them. It can be thought of as a very specialized
configuration management system (e.g. puppet, chef, whatever) for doing
just one thing (setting up a system for Cloudmin). It has basic dependency
resolution (via topological sort), logging, and ties into the Webmin API to
make some common tasks (like starting/stopping services, setting them to run
on boot) simpler to code.

=head1 SYNOPSIS

    my $bundle = Cloudmin::Config->new(bundle	=> 'KVM');
    $bundle->run();

You can also call it with specific plugins, rather than a whole bundle of
plugins.

    my $plugin = Cloudmin::Config->new(include => 'FirewallD');
    $plugin->run();

Adding new features to the installer, or modifying installer features, should
be done by creating new plugins or by adding to existing ones.

=head1 DESCRIPTION

This is a mini-framework for configuring elements of a Cloudmin system. It
uses Webmin as a library to abstract common configuration tasks, provides a
friendly status indicator, and makes it easy to pick and choose the kind of
configuration you want (should you choose to go that route). The Cloudmin
install script chooses KVM bundle, and performs the  configuration for the
whole stack.

It includes plugins for all of the common tasks in a Cloudmin system, such
as virtualization management tools, and support services like BIND and network
configuration.

=head1 INSTALLATION

The recommended installation method is to use native packages for your
distribution. We provide packages for Debian, Ubuntu, CentOS/RHEL, and Fedora
in our repositories.

You can use the standard Perl process to install from the source tarball or
git clone:

    perl Makefile.PL
    make
    make test
    make install

Or, use your system native package manager. The following assumes you have all
of the packages needed to build native packages installed.

To build a dpkg for Debian/Ubuntu:

    dpkg-buildpackage -b -rfakeroot -us -uc

And, for CentOS/Fedora/RHEL/etc. RPM distributions:

    dzil build # Creates a tarball
    cp Cloudmin-Config-*.tar.gz ~/rpmbuild/SOURCES
    rpmbuild -bb cloudmin-config.spec

=head1 ATTRIBUTES

=over

=item bundle

Selects the plugin bundle to be installed. A bundle is a list of plugins
configured in a C<Cloudmin::Config::*> class.

=item include

One or more additional plugins to include in the C<run()>. This can be
used alongside C<bundle> or by itself. Dependencies will also be run, and
there is no way to disable dependencies (because they're depended on!).

=item exclude

One or more plugins to remove from the selected C<bundle>. Plugins that are
needed to resolve dependencies will be re-added automatically.

=back

=head1 METHODS

=over

=item run

This method figures out which plugins to run (based on the C<bundle>,
C<include>, and C<exclude> attributes.

=back

=head1 LICENSE AND COPYRIGHT

Licensed under the GPLv3. Copyright 2017-2025, Joe Cooper <joe@virtualmin.com>
