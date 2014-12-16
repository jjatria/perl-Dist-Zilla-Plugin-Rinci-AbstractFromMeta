package Dist::Zilla::Plugin::Rinci::AbstractFromMeta;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Moose;
use namespace::autoclean;

with (
    'Dist::Zilla::Role::BeforeBuild',
    'Dist::Zilla::Role::FileMunger',
    'Dist::Zilla::Role::FileFinderUser' => {
        default_finders => [':InstallModules', ':ExecFiles'],
    },
);

use Data::Dump qw(dump);
use File::Slurp::Tiny qw(read_file);
use File::Spec::Functions qw(catfile);

sub _get_from_module {
    my ($self, $filename) = @_;

    (my $mod_p = $filename) =~ s!^lib/!!;
    require $mod_p;

    # find out the package of the file
    (my $pkg = $mod_p) =~ s/\.pm\z//; $pkg =~ s!/!::!g;

    no strict 'refs';
    my $metas = \%{"$pkg\::SPEC"};

    my $abstract;
    {
        if ($metas->{':package'}) {
            $abstract = $metas->{':package'}{summary};
            last if $abstract;
        }

        # list functions, sorted by the length of its metadata dump
        my @funcs =
            map {$_->[0]}
                sort {length($a->[1]) <=> length($b->[1])}
                    map { [$_, dump($metas->{$_})] }
                        grep {/\A\w+\z/} keys %$metas;
        if (@funcs) {
            $abstract = $metas->{ $funcs[0] }{summary};
            last if $abstract;
        }
    }
    return $abstract;
}

sub _get_from_script {
    my ($self, $filename) = @_;

    # check if script uses Perinci::CmdLine
    my $ct = read_file $filename;
    unless ($ct =~ /\b(?:use|require)\s+
                    (Perinci::CmdLine(?:::Lite|::Any)?)\b/x) {
        return undef;
    }

    require UUID::Random;
    my $tag=UUID::Random::generate();

    my @cmd = ($^X, "-Ilib", "-MPerinci::CmdLine::Base::Patch::DumpAndExit=-tag,$tag");
    push @cmd, $filename;
    push @cmd, "--version";
    require Capture::Tiny;
    my ($stdout, $stderr, $exit) = Capture::Tiny::capture(
        sub { system @cmd },
    );
    my $cli;
    if ($stdout =~ /^# BEGIN DUMP $tag\s+(.*)^# END DUMP $tag/ms) {
        $cli = eval $1;
        if ($@) {
            die "Script '$filename' detected as using Perinci::CmdLine, ".
                "but error in eval-ing captured object: $@, ".
                    "raw captured object: <<<$1>>>";
        }
        if (!blessed($cli)) {
            die "Script '$filename' detected as using Perinci::CmdLine, ".
                "but didn't get an object?, raw captured output=<<$stdout>>";
        }
    } else {
        die "Script '$filename' detected as using Perinci::CmdLine, ".
            "but can't capture object, raw captured output: stdout=<<$stdout>>, stderr=<<$stderr>>";
    }

    return $cli->{summary} if $cli->{summary};
    return undef unless $cli->{url};

    # XXX handle embedded but not in /main
    if ($cli->{url} =~ m!^(pl:)?/main/!) {
        # function is embedded in script (/main/FOO), we need to load the
        # metadata in-process
        no warnings;
        %main::SPEC = (); # empty first to avoid mixing with other scripts'
        (undef, undef, undef) = Capture::Tiny::capture(sub {
            eval q{package main; use Perinci::CmdLine::Base::Patch::DumpAndExit -tag=>'$tag', -exit_method=>'die'; do "$filename"};
        });
    }
    state $pa = do { require Perinci::Access; Perinci::Access->new };
    my $res = $pa->request(meta => $cli->{url});
    die "Can't meta $cli->{url}: $res->[0] - $res->[1]" unless $res->[0] == 200;
    my $meta = $res->[2];

    return $meta->{summary};
}

sub _get_abstract_from_meta {
    my ($self, $filename) = @_;

    local @INC = @INC;
    unshift @INC, 'lib';

    my $content = do {
        open my($fh), "<", $filename or die "Can't open $filename: $!";
        local $/;
        ~~<$fh>;
    };

    unless ($content =~ m{^#[ \t]*ABSTRACT:[ \t]*([^\n]*)[ \t]*$}m) {
        $self->log_debug(["Skipping %s: no # ABSTRACT", $filename]);
        return undef;
    }

    my $abstract = $1;
    if ($abstract =~ /\S/) {
        $self->log_debug(["Skipping %s: Abstract already filled (%s)", $filename, $abstract]);
        return $abstract;
    }

    # XXX if script, do()
    if ($filename =~ m!^lib/!) {
        $self->log_debug(["Getting abstract for module %s", $filename]);
        $abstract = $self->_get_from_module($filename);
    } else {
        $self->log_debug(["Getting abstract for script %s", $filename]);
        $abstract = $self->_get_from_script($filename);
    }
    $abstract;
}

# dzil also wants to get abstract for main module to put in dist's
# META.{yml,json}
sub before_build {
   my $self  = shift;
   my $name  = $self->zilla->name;
   my $class = $name; $class =~ s{ [\-] }{::}gmx;
   my $filename = $self->zilla->_main_module_override ||
       catfile( 'lib', split m{ [\-] }mx, "${name}.pm" );

   $filename or die 'No main module specified';
   -f $filename or die "Path ${filename} does not exist or not a file";
   open my $fh, '<', $filename or die "File ${filename} cannot open: $!";

   my $abstract = $self->_get_abstract_from_meta($filename);
   die "Can't get abstract for main module " . $filename unless $abstract;

   $self->zilla->abstract($abstract);
   return;
}

sub munge_files {
    my $self = shift;
    $self->munge_file($_) for @{ $self->found_files };
}

sub munge_file {
    my ($self, $file) = @_;
    my $content = $file->content;

    my $abstract = $self->_get_abstract_from_meta($file->name);
    unless (defined $abstract) {
        die "Can't figure out abstract for " . $file->name;
    }

    $content =~ s{^#\s*ABSTRACT:.*}{# ABSTRACT: $abstract}m
        or die "Can't insert abstract for " . $file->name;
    $self->log(["inserting abstract for %s (%s)", $file->name, $abstract]);
    $file->content($content);
}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Fill out abstract from Rinci metadata

=for Pod::Coverage .+

=head1 SYNOPSIS

In C<dist.ini>:

 [Rinci::AbstractFromMeta]

In your module/script:

 # ABSTRACT:

During build, abstract will be filled with summary from Rinci package metadata,
or Rinci function metadata (if there are more than one, will pick "the largest"
function, measured by the dump length).

If Abstract is already filled, will leave it alone.


=head1 DESCRIPTION

This plugin is another DRY module. If you have already put summaries in Rinci
metadata, why repeat it in the dzil Abstract?


=head1 SEE ALSO

L<Rinci>

