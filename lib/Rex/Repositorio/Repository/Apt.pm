#
# (c) Jan Gehring <jan.gehring@gmail.com>
#
# vim: set ts=2 sw=2 tw=0:
# vim: set expandtab:

package Rex::Repositorio::Repository::Apt;

use Moose;
use Try::Tiny;
use File::Basename qw'basename';
use Data::Dumper;
use Digest::SHA;
use Carp;
use Params::Validate qw(:all);
use File::Spec;
use File::Path;
use IO::All;

extends "Rex::Repositorio::Repository::Base";

sub mirror {
  my ( $self, %option ) = @_;

  $self->repo->{url} =~ s/\/$//;
  $self->repo->{local} =~ s/\/$//;
  my $name = $self->repo->{name};

  my $dist = $self->repo->{dist};

  my @archs = split /, ?/, $self->repo->{arch};

  ##############################################################################
  # get meta data
  ##############################################################################
  my $url      = $self->repo->{url} . "/dists/$dist";
  my $contents = $self->download("$url/Release");
  my $ref      = $self->_parse_debian_release_file($contents);

  for my $file_data ( @{ $ref->{SHA1} } ) {
    my $file_url = $url . "/" . $file_data->{file};
    my $file     = $file_data->{file};

    $self->download_metadata(
      url  => $file_url,
      dest => $self->repo->{local} . "/dists/$dist/$file",
      cb   => sub {
        if ( $file eq "Release" ) { return; }

        $self->_checksum( @_, "sha1", $file_data->{checksum} );
      },
      force => $option{update_metadata},
    );

  }

  ##############################################################################
  # download packages
  ##############################################################################
  my @components = split /, ?/, $self->repo->{components};
  for my $component (@components) {

    my $local_components_path =
      $self->app->get_repo_dir( repo => $self->repo->{name} )
      . "/dists/$dist/$component";

    for my $arch (@archs) {
      $self->app->logger->debug("Processing ($name, $component) $dist / $arch");

      my $local_packages_path =
        $local_components_path . "/binary-$arch/Packages";

      $self->app->logger->debug("Reading: $local_packages_path");
      my $content     = io($local_packages_path)->slurp;
      my $package_ref = $self->_parse_debian_package_file($content);

      for my $package ( @{$package_ref} ) {
        my $package_url  = $self->repo->{url} . "/" . $package->{Filename};
        my $package_name = $package->{Package};

        my $local_file = $self->repo->{local} . "/" . $package->{Filename};
        $self->download_package(
          url  => $package_url,
          name => $package_name,
          dest => $local_file,
          cb   => sub {
            $self->_checksum( @_, "sha1", $package->{SHA1} );
          },
          force => $option{update_files}
        );
      }
    }
  }

  ##############################################################################
  # download rest of metadata
  ##############################################################################
  for my $arch (@archs) {
    for my $suffix (qw/bz2 gz/) {
      my $file_url = $url . "/Contents-$arch.$suffix";
      my $file     = "Contents-$arch.$suffix";

      try {
        $self->download_metadata(
          url   => $file_url,
          dest  => $self->repo->{local} . "/dists/$dist/$file",
          force => $option{update_metadata},
        );
      }
      catch {
        $self->app->logger->error($_);
      };
    }
  }

}

sub _parse_debian_release_file {
  my ( $self, $content ) = @_;

  my $ret     = {};
  my $section = "main";
  for my $line ( split /\n/, $content ) {
    chomp $line;
    next if ( $line =~ m/^\s*?$/ );

    if ( $line !~ m/^\s/ ) {
      my ( $key, $value ) = split /:/, $line;
      $value =~ s/^\s*|\s*$//;
      $section = $key;
      if ($value) {
        $ret->{$key} = $value;
      }
      else {
        $ret->{$key} = [];
      }
    }

    if ( $line =~ m/^\s/ ) {
      $line =~ s/^\s//;
      my @values = split /\s+/, $line;
      if ( $ret->{$section} && !ref $ret->{$section} ) {
        $ret->{$section} = [ $ret->{$section} ];
      }
      push @{ $ret->{$section} },
        {
        checksum => $values[0],
        size     => $values[1],
        file     => $values[2],
        };
    }
  }

  return $ret;
}

sub _parse_debian_package_file {
  my ( $self, $content ) = @_;

  my @ret;

  my $section;
  my $current_section;
  for my $line ( split /\n/, $content ) {
    chomp $line;

    if ( $line =~ m/^$/ ) {
      push @ret, $current_section;
      $current_section = {};
      next;
    }

    my ( $key, $value ) = ( $line =~ m/^([A-Z0-9a-z\-]+):(.*)$/ );

    if ($key) {
      $value =~ s/^\s//;
      $section = $key;
      $current_section->{$key} = $value;
    }
    else {
      $value = $line;
      $value =~ s/^\s//;

      if ( $current_section->{$section} && !ref $current_section->{$section} ) {
        $current_section->{$section} = [ $current_section->{$section} ];
      }

      push @{ $current_section->{$section} }, $value;
    }
  }

  return \@ret;
}

1;
