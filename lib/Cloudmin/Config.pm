package Cloudmin::Config;

# ABSTRACT: Configure a system for use by Cloudmin
use strict;
use warnings;
no warnings qw(once);    # We've got some globals that effect Webmin behavior
use 5.026;
use Module::Load;
use Term::ANSIColor qw(:constants);
use Log::Log4perl qw(:easy);

# globals
our (%gconfig, %uconfig, %miniserv, %uminiserv);
our ($root_directory, $config_directory);
our ($trust_unknown_referers, $no_acl_check, $error_must_die, $file_cache);

# new(class, [options]) Selects plugins, optional tests and the log file.
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

# run(self) Runs plugins in dependency order and stops on failure.
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
  for my $name (@plugins) {
    my $pkg = "Cloudmin::Config::Plugin::$name";
    load $pkg || die "Loading Plugin failed: $name";
    my $plugin = $pkg->new(total => $total, bundle => $self->{bundle});
    my $ok = eval { $plugin->actions(); 1 };
    # Add the plugin name to exceptions before stopping configuration.
    if (!$ok) {
      my $error = $@ || "Configuration failed";
      $log->error("$name: $error");
      die "$name: $error";
    }
    # Run optional checks only after the plugin finishes successfully.
    if ($self->{test} && $plugin->can('tests')) {
      $plugin->tests();
    }
  }
  return 1;
}

# list_bundles(self) Returns sorted bundle names from the installed tree.
sub list_bundles {
  my $self = shift;

  # Figure out our module home directory
  my $modpath = $INC{'Cloudmin/Config.pm'};
  use File::Basename;
  my $bundlepath = dirname($modpath) . '/Config';
  opendir(my $DIR, $bundlepath) or die "Cannot list bundles: $!\n";
  my @bundles = grep(/\.pm$/, readdir($DIR));
  closedir($DIR);
  # Internal helpers share this directory but are not installation bundles.
  @bundles = grep { $_ ne 'Plugin.pm' && $_ ne 'Libvirt.pm' } @bundles;
  for (@bundles) {s/\.pm$//}
  @bundles = sort(@bundles);
  return @bundles;
}

# list_plugins(self) Returns sorted plugin names from the installed tree.
sub list_plugins {
  my $self = shift;

  # Figure out our module home directory
  require Cloudmin::Config::Plugin;
  my $modpath = $INC{'Cloudmin/Config/Plugin.pm'};
  use File::Basename;
  my $pluginpath = dirname($modpath) . '/Plugin';
  opendir(my $DIR, $pluginpath) or die "Cannot list plugins: $!\n";
  my @plugins = grep(/\.pm$/, readdir($DIR));
  closedir($DIR);
  for (@plugins) {s/\.pm$//}
  @plugins = sort(@plugins);
  return @plugins;
}

# _gather_plugins(self) Resolves bundle selection and explicit exclusions.
sub _gather_plugins {
  my ($self) = @_;
  my @plugins;
  # A named bundle supplies the initial plugin selection.
  if ($self->{bundle}) {
    _valid_name($self->{bundle});
    my $pkg = "Cloudmin::Config::$self->{bundle}";
    load $pkg;
    @plugins = _flat($pkg->new()->plugins());
  }
  # Merge explicit names and exclusions without changing their order.
  push @plugins, _flat($self->{include});
  my %excluded = map { _valid_name($_); $_ => 1 } _flat($self->{exclude});
  # Installation must finish with the full readiness check.
  die "Readiness is required by the KVM bundle\n"
    if ($self->{bundle} || '') eq 'KVM' && $excluded{Readiness};
  return grep { !$excluded{$_} } _uniq(@plugins);
}

# _order_plugins(self, [names...]) Orders plugins and their dependencies.
# Names may be scalars or array references; no actions run here.
sub _order_plugins {
  my ($self, @plugins) = @_;
  my %excluded = map { $_ => 1 } _flat($self->{exclude});
  my (%visiting, %done, @ordered);
  my $visit;
  # visit(name) Adds each dependency before the plugin that requires it.
  $visit = sub {
    my ($name) = @_;
    _valid_name($name);
    # Dependencies cannot override an explicit exclusion.
    die "Required plugin $name was excluded\n" if $excluded{$name};
    # Revisiting the current path is a cycle; completed branches are safe.
    die "Dependency cycle at $name\n" if $visiting{$name};
    return if $done{$name};
    # Load metadata, visit dependencies, then mark this plugin complete.
    my $pkg = "Cloudmin::Config::Plugin::$name";
    load $pkg;
    $visiting{$name} = 1;
    $visit->($_) for @{$pkg->new()->depends() || []};
    delete $visiting{$name};
    $done{$name} = 1;
    push @ordered, $name;
  };
  $visit->($_) for _flat(@plugins);
  undef $visit; # Release the recursive closure after resolving the graph.
  return @ordered;
}

# _valid_name(name) Rejects paths and arbitrary Perl package expressions.
sub _valid_name {
  my ($name) = @_;
  die "Invalid plugin or bundle name\n"
    unless defined($name) && $name =~ /\A[A-Za-z][A-Za-z0-9]*\z/;
  return $name;
}

# _uniq([values...]) Preserves the first occurrence of each plugin name.
sub _uniq {
  my %seen;
  return grep { !$seen{$_}++ } @_;
}

# _flat([values...]) Flattens names and nested array references, skipping undef.
sub _flat {
  return map { ref($_) eq 'ARRAY' ? _flat(@$_) : $_ } grep { defined } @_;
}

1;

__END__

=pod

=head1 NAME

Cloudmin::Config - Configure a Cloudmin KVM host

=head1 SYNOPSIS

    Cloudmin::Config->new(bundle => 'KVM')->run();

=head1 DESCRIPTION

Loads configuration plugins and their dependencies before executing them in
order. Excluded dependencies, cycles and plugin failures stop configuration.
See README.pod for supported hosts, installation and testing instructions.

=head1 LICENSE AND COPYRIGHT

Licensed under the GPLv3. Copyright 2017-2026 Cloudmin, LLC.

Authors: Ilia Ross <ilia@webmin.dev>, Joe Cooper <joe@webmin.com>,
and Jamie Cameron <jamie@webmin.com>.

=cut
