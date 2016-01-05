
package Bio::Path::Find::App::PathFind::Data;

# ABSTRACT: find files and directories

use v5.10; # for "say"

use MooseX::App::Command;
use namespace::autoclean;
use MooseX::StrictConstructor;

use Carp qw( carp );
use Path::Class;
use Try::Tiny;
use IO::Compress::Gzip;
use File::Temp;
use Text::CSV_XS;
use Archive::Tar;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use Cwd;
use Term::ProgressBar::Simple;

use Bio::Path::Find::Exception;

use Types::Standard qw(
  ArrayRef
  +Str
  +Bool
);

use Bio::Path::Find::Types qw(
  FileType
  QCState
  +PathClassDir  DirFromStr
  +PathClassFile FileFromStr
);

extends 'Bio::Path::Find::App::PathFind';

with 'Bio::Path::Find::App::Role::AppRole';

#-------------------------------------------------------------------------------
#- usage text ------------------------------------------------------------------
#-------------------------------------------------------------------------------

=head1 USAGE

pathfind data --id <id> --type <ID type> [options]

=head1 DESCRIPTION

Given a study ID, lane ID, or sample ID, or a file containing a list of IDs,
this script will output the path(s) on disk to the data associated with the
specified sequencing run(s).

=head1 OPTIONS

=head2 REQUIRED OPTIONS

=over

=item --id -i <ID>

The ID for which to search, or the name of a file on disk from which the search
IDs should be read.

=item --type -t <ID type>

The type of ID specified by B<--id>, or B<file> to read IDs from disk. Must be
one of B<lane>, B<sample>, B<study>, B<library>, B<species>, B<study> or
B<file>.

=item --file-id-type -ft <type of ID in file>

The type of ID found in the specified file

=back

=head2 FURTHER OPTIONS

=head3 FILTERING

=over

=item --qc | -q <QC status>

Show information only for lanes with the specified quality control status. Must
be one of B<passed>, B<failed>, or B<pending>.

=item --filetype | -f <file type>

If set, the script will list only files of the specified type. If B<--filetype>
is not provided, the default behaviour is to return the path to the directory
containing all files for the given lane. Must be one of B<bam>, B<corrected>,
B<fastq>, or B<pacbio>.

=back

=head3 OUTPUT

pathfind can output data in various ways. The default behaviour is to list
the directories containing data for the specified ID(s).

=over

=item --archive | -a [<archive name>]

If an archive name is given, the found data will be written as a tar archive
with the specified name. If the C<--archive> option is given without a value,
the archive will be named according to the search ID. See also C<--zip>.

=item --zip | -z

Write a zip archive instead of a tar archive. Must be used along with the
C<--archive> option.

=item --symlink | -l [<link dir>]

Create symbolic links to the found data. If a link directory is specified,
the links will be created in that directory. The directory itself will be
created if it does not already exist. If a link directory is not specified,
the links will be created in the current working directory.

=item --stats | -s [<CSV file>]

Create a comma-separated-values (CSV) file containing the statistics for
the found lanes. If a filename is supplied, the CSV data will be written
to that file. If no filename is given, a filename will be generated from
the input ID. See also C<--csv-separator>.

=item --csv-separator | -c <separator>

Specify the separator that should be used when writing CSV data. The default is
a comma (",") but an alternative would be a tab character ("	").

=item --rename | -r

When collecting files in archives or when symlinking data files, convert
hashes ("#") in filenames into underscores ("_"). This conversion is
always done when generating names for archives or stats CSV files.

=back

=head3 SWITCHES

=item --no-progress-bars | -n

Don't show progress bars when performing slow operations. Useful if using
C<pathfind> as part of a larger script.

=item --no-tar-compression | -u

Don't compress tar archives. Since data files are already gzip compressed, the
extra compression often won't achieve much. Leaving the archive uncompressed
will speed up the archiving operation.

=item --verbose | -v

Show (lots of) debugging messages.

=item --help | -h | -?

Show the usage message.

=back

=cut

# old pathfind help text:
#
# Usage: /software/pathogen/internal/prod/bin/pathfind
#                 -t|type         <study|lane|file|library|sample|species>
#                 -i|id           <study id|study name|lane name|file of lane names>
#         --file_id_type     <lane|sample> define ID types contained in file. default = lane
#                 -h|help         <this help message>
#                 -f|filetype     <fastq|bam|pacbio|corrected>
#                 -l|symlink      <create sym links to the data and define output directory>
#                 -a|archive      <name for archive containing the data>
#                 -r|rename   <replace # in symlinks with _>
#                 -s|stats        <output statistics>
#                 -q|qc           <passed|failed|pending>
#                 --prefix_with_library_name <prefix the symlink with the sample name>
#
#         Given a study, lane or a file containing a list of lanes or samples, this script will output the path (on pathogen disk) to the data associated with the specified study or lane.
#         Using the option -qc (passed|failed|pending) will limit the results to data of the specified qc status.
#         Using the option -filetype (fastq, bam, pacbio or corrected) will return the path to the files of this type for the given data.
#         Using the option -symlink will create a symlink to the queried data in the current directory, alternativley an output directory can be specified in which the symlinks will be created.
#         Similarly, the archive option will create and archive (.tar.gz) of the data under a default file name unless one is specified.
# =cut

#-------------------------------------------------------------------------------
#- public attributes -----------------------------------------------------------
#-------------------------------------------------------------------------------

option 'filetype' => (
  documentation => 'type of files to find',
  is            => 'ro',
  isa           => FileType,
  cmd_aliases   => 'f',
);

option 'qc' => (
  documentation => 'filter results by lane QC state',
  is            => 'ro',
  isa           => QCState,
  cmd_aliases   => 'q',
);

option 'rename' => (
  documentation => 'replace hash (#) with underscore (_) in filenames',
  is            => 'rw',
  isa           => Bool,
  cmd_aliases   => 'r',
);

option 'no_tar_compression' => (
  documentation => "don't compress tar archives",
  is            => 'rw',
  isa           => Bool,
  cmd_flag      => 'no-tar-compression',
  cmd_aliases   => 'u',
);

option 'zip' => (
  documentation => 'archive data in ZIP format',
  is            => 'ro',
  isa           => Bool,
  cmd_aliases   => 'z',
);

#---------------------------------------

# this option can be used as a simple switch ("-l") or with an argument
# ("-l mydir"). It's a bit fiddly to set that up...

option 'symlink' => (
  documentation => 'create symlinks for data files in the specified directory',
  is            => 'ro',
  cmd_aliases   => 'l',
  trigger       => \&_check_for_symlink_value,
  # no "isa" because we want to accept both Bool and Str and it doesn't seem to
  # be possible to specify that using the combination of MooseX::App and
  # Type::Tiny that we're using here
);

# set up a trigger that checks for the value of the "symlink" command-line
# argument and tries to decide if it's a boolean, in which case we'll generate
# a directory name to hold links, or a string, in which case we'll treat that
# string as a directory name.
sub _check_for_symlink_value {
  my ( $self, $new, $old ) = @_;

  if ( not defined $new ) {
    # make links in a directory whose name we'll set ourselves
    $self->_symlink_flag(1);
  }
  elsif ( not is_Bool($new) ) {
    # make links in the directory specified by the user
    $self->_symlink_flag(1);
    $self->_symlink_dir( dir $new );
  }
  else {
    # don't make links. Shouldn't ever get here
    $self->_symlink_flag(0);
  }
}

# private attributes to store the (optional) value of the "symlink" attribute.
# When using all of this we can check for "_symlink_flag" being true or false,
# and, if it's true, check "_symlink_dir" for a value
has '_symlink_dir'  => ( is => 'rw', isa => PathClassDir );
has '_symlink_flag' => ( is => 'rw', isa => Bool );

#---------------------------------------

# set up "archive" like we set up "symlink". No need to register a new
# subtype again though

option 'archive' => (
  documentation => 'filename for archive',
  is            => 'rw',
  # no "isa" because we want to accept both Bool and Str
  cmd_aliases   => 'a',
  trigger       => \&_check_for_archive_value,
);

sub _check_for_archive_value {
  my ( $self, $new, $old ) = @_;

  if ( not defined $new ) {
    $self->_archive_flag(1);
  }
  elsif ( not is_Bool($new) ) {
    $self->_archive_flag(1);
    $self->_archive_dir( dir $new );
  }
  else {
    $self->_archive_flag(0);
  }
}

has '_archive_dir'  => ( is => 'rw', isa => PathClassDir );
has '_archive_flag' => ( is => 'rw', isa => Bool );

#---------------------------------------

option 'stats' => (
  documentation => 'filename for statistics CSV output',
  is            => 'rw',
  # no "isa" because we want to accept both Bool and Str
  cmd_aliases   => 's',
  trigger       => \&_check_for_stats_value,
);

sub _check_for_stats_value {
  my ( $self, $new, $old ) = @_;

  if ( not defined $new ) {
    $self->_stats_flag(1);
  }
  elsif ( not is_Bool($new) ) {
    $self->_stats_flag(1);
    $self->_stats_file( file $new );
  }
  else {
    $self->_stats_flag(0);
  }
}

has '_stats_file' => ( is => 'rw', isa => PathClassFile );
has '_stats_flag' => ( is => 'rw', isa => Bool );

#-------------------------------------------------------------------------------
#- public methods --------------------------------------------------------------
#-------------------------------------------------------------------------------

=head1 METHODS

=head2 run

Find files according to the input parameters.

=cut

sub run {
  my $self = shift;

  # set up the finder

  # build the parameters for the finder. Omit undefined options or Moose spits
  # the dummy (by design)
  my %finder_params = (
    ids  => $self->_ids,
    type => $self->_type,
  );
  $finder_params{qc}       = $self->qc       if defined $self->qc;
  $finder_params{filetype} = $self->filetype if defined $self->filetype;

  # find lanes
  my $lanes = $self->_finder->find_lanes(%finder_params);

  $self->log->debug( 'found ' . scalar @$lanes . ' lanes' );

  if ( scalar @$lanes < 1 ) {
    say STDERR 'No data found.';
    exit;
  }

  # do something with the found lanes
  if ( $self->_symlink_flag ) {
    $self->_make_symlinks($lanes);
  }
  elsif ( $self->_archive_flag ) {
    $self->_make_archive($lanes);
  }
  elsif ( $self->_stats_flag ) {
    $self->_make_stats($lanes);
  }
  else {
    $_->print_paths for ( @$lanes );
  }

}

#-------------------------------------------------------------------------------
#- private methods -------------------------------------------------------------
#-------------------------------------------------------------------------------

# make symlinks for found lanes

sub _make_symlinks {
  my ( $self, $lanes ) = @_;

  my $dest;

  if ( $self->_symlink_dir ) {
    $self->log->debug('symlink attribute specifies a dir name');
    $dest = $self->_symlink_dir;
  }
  else {
    $self->log->debug('symlink attribute is a boolean; building a dir name');
    $dest = dir( getcwd(), 'pathfind_' . $self->_renamed_id );
  }

  try {
    $dest->mkpath unless -d $dest;
  } catch {
    Bio::Path::Find::Exception->throw(
      msg => "ERROR: couldn't make link directory ($dest)"
    );
  };

  # should be redundant, but...
  Bio::Path::Find::Exception->throw( msg =>  "ERROR: not a directory ($dest)" )
    unless -d $dest;

  say STDERR "Creating links in '$dest'";

  my $pb = $self->config->{no_progress_bars}
         ? 0
         : Term::ProgressBar::Simple->new( {
             name   => 'linking',
             count  => scalar @$lanes,
             remove => 1,
           } );

  my $i = 0;
  foreach my $lane ( @$lanes ) {
    $lane->make_symlinks( dest => $dest, rename => $self->rename );
    $pb++;
  }
}

#-------------------------------------------------------------------------------

# make an archive of the data files for the found lanes, either tar or zip,
# depending on the "zip" attribute

sub _make_archive {
  my ( $self, $lanes ) = @_;

  my $archive_filename;

  if ( $self->_archive_dir ) {
    $self->log->debug('_archive_dir attribute is set; using it as a filename');
    $archive_filename = $self->_archive_dir;
  }
  else {
    $self->log->debug('_archive_dir attribute is not set; building a filename');
    # we'll ALWAYS make a sensible name for the archive itself (use renamed_id)
    if ( $self->zip ) {
      $archive_filename = 'pathfind_' . $self->_renamed_id . '.zip';
    }
    else {
      $archive_filename = 'pathfind_' . $self->_renamed_id
                          . ( $self->no_tar_compression ? '.tar' : '.tar.gz' );
    }
  }
  $archive_filename = file $archive_filename;

  say STDERR "Archiving lane data to '$archive_filename'";

  # collect the list of files to archive
  my ( $filenames, $stats ) = $self->_collect_filenames($lanes);

  # write a CSV file with the stats and add it to the list of files that
  # will go into the archive
  my $temp_dir = File::Temp->newdir;
  my $stats_file = file( $temp_dir, 'stats.csv' );
  $self->_write_stats_csv($stats, $stats_file);

  push @$filenames, $stats_file;

  #---------------------------------------

  # zip or tar ?
  if ( $self->zip ) {
    # build the zip archive in memory
    my $zip = $self->_build_zip_archive($filenames);

    print STDERR 'Writing zip file... ';

    # write it to file
    try {
      unless ( $zip->writeToFileNamed($archive_filename->stringify) == AZ_OK ) {
        print STDERR "failed\n";
        Bio::Path::Find::Exception->throw( msg => "ERROR: couldn't write zip file ($archive_filename)" );
      }
    } catch {
      Bio::Path::Find::Exception->throw( msg => "ERROR: error while writing zip file ($archive_filename): $_" );
    };

    print STDERR "done\n";
  }
  else {
    # build the tar archive in memory
    my $tar = $self->_build_tar_archive($filenames);

    # we could write the archive in a single call, like this:
    #   $tar->write( $tar_filename, COMPRESS_GZIP );
    # but it's nicer to have a progress bar. Since gzipping and writing can be
    # performed as separate operations, we'll do progress bars for both of them

    # get the contents of the tar file. This is a little slow but we can't
    # break it down and use a progress bar, so at least tell the user what's
    # going on
    print STDERR 'Building tar file... ';
    my $tar_contents = $tar->write;
    print STDERR "done\n";

    # gzip compress the archive ?
    my $output = $self->no_tar_compression
               ? $tar_contents
               : $self->_compress_data($tar_contents);

    # and write it out, gzip compressed
    $self->_write_data( $output, $archive_filename );
  }

  #---------------------------------------

  # list the contents of the archive
  say $_ for @$filenames;
}

#-------------------------------------------------------------------------------

# retrieves the list of filenames associated with the supplied lanes

sub _collect_filenames {
  my ( $self, $lanes ) = @_;

  my $pb = $self->config->{no_progress_bars}
         ? 0
         : Term::ProgressBar::Simple->new( {
             name   => 'finding files',
             count  => scalar @$lanes,
             remove => 1,
           } );

  # collect the lane stats as we go along. Store the headers for the stats
  # report as the first row
  my @stats = ( $lanes->[0]->stats_headers );

  my @filenames;
  my $i = 0;
  foreach my $lane ( @$lanes ) {

    # if the Finder was set up to look for a specific filetype, we don't need
    # to do a find here. If it was not given a filetype, it won't have looked
    # for data files, just the directory for the lane, so we need to find data
    # files here explicitly
    $lane->find_files('fastq') if not $self->filetype;

    foreach my $filename ( $lane->all_files ) {
      push @filenames, $filename;
    }

    # store the stats for this lane
    push @stats, $lane->stats;

    $pb++;
  }

  return ( \@filenames, \@stats );
}

#-------------------------------------------------------------------------------

# creates a tar archive containing the specified files

sub _build_tar_archive {
  my ( $self, $filenames ) = @_;

  my $tar = Archive::Tar->new;

  my $pb = $self->config->{no_progress_bars}
         ? 0
         : Term::ProgressBar::Simple->new( {
             name   => 'adding files',
             count  => scalar @$filenames,
             remove => 1,
           } );

  foreach my $filename ( @$filenames ) {
    $tar->add_files($filename);
    $pb++;
  }

  # the files are added with their full paths. We want them to be relative,
  # so we'll go through the archive and rename them all. If the "-rename"
  # option is specified, we'll also rename the individual files to convert
  # hashes to underscores
  foreach my $orig_filename ( @$filenames ) {

    my $tar_filename = $self->_rename_file($orig_filename);

    # filenames in the archive itself are relative to the root directory, i.e.
    # they lack a leading slash. Trim off that slash before trying to rename
    # files in the archive, otherwise they're simply not found. Take a copy
    # of the original filename before we trim it, to avoid stomping on the
    # original
    ( my $trimmed_filename = $orig_filename ) =~ s|^/||;

    $tar->rename( $trimmed_filename, $tar_filename )
      or carp "WARNING: couldn't rename '$trimmed_filename' in archive";
  }

  return $tar;
}

#-------------------------------------------------------------------------------

# creates a ZIP archive containing the specified files

sub _build_zip_archive {
  my ( $self, $filenames ) = @_;

  my $zip = Archive::Zip->new;

  my $pb = $self->config->{no_progress_bars}
         ? 0
         : Term::ProgressBar::Simple->new( {
             name   => 'adding files',
             count  => scalar @$filenames,
             remove => 1,
           } );

  foreach my $orig_filename ( @$filenames ) {
    my $zip_filename  = $self->_rename_file($orig_filename);

    # this might not be strictly necessary, but there were some strange things
    # going on while testing this operation: stringify the filenames, to avoid
    # the Path::Class::File object going into the zip archive
    $zip->addFile($orig_filename->stringify, $zip_filename->stringify);

    $pb++;
  }

  return $zip;
}

#-------------------------------------------------------------------------------

# generates a new filename by converting hashes to underscores in the supplied
# filename. Also converts the filename to unix format, for use with tar and
# zip

sub _rename_file {
  my ( $self, $old_filename ) = @_;

  my $new_basename = $old_filename->basename;

  # honour the "-rename" option
  $new_basename =~ s/\#/_/g if $self->rename;

  # add on the folder to get the relative path for the file in the
  # archive
  ( my $folder_name = $self->id ) =~ s/\#/_/g;

  my $new_filename = file( $folder_name, $new_basename );

  # filenames in an archive are specified as Unix paths (see
  # https://metacpan.org/pod/Archive::Tar#tar-rename-file-new_name)
  $old_filename = file( $old_filename )->as_foreign('Unix');
  $new_filename = file( $new_filename )->as_foreign('Unix');

  $self->log->debug( "renaming |$old_filename| to |$new_filename|" );

  return $new_filename;
}

#-------------------------------------------------------------------------------

# gzips the supplied data and returns the compressed data

sub _compress_data {
  my ( $self, $data ) = @_;

  my $max        = length $data;
  my $num_chunks = 100;
  my $chunk_size = int( $max / $num_chunks );

  # set up the progress bar
  my $pb = $self->config->{no_progress_bars}
         ? 0
         : Term::ProgressBar::Simple->new( {
             name   => 'gzipping',
             count  => $num_chunks,
             remove => 1,
           } );

  my $compressed_data;
  my $offset      = 0;
  my $remaining   = $max;
  my $z           = IO::Compress::Gzip->new( \$compressed_data );
  while ( $remaining > 0 ) {
    # write the data in chunks
    my $chunk = ( $chunk_size > $remaining )
              ? substr $data, $offset
              : substr $data, $offset, $chunk_size;

    $z->print($chunk);

    $offset    += $chunk_size;
    $remaining -= $chunk_size;
    $pb++;
  }

  $z->close;

  return $compressed_data;
}

#-------------------------------------------------------------------------------

# writes the supplied data to the specified file. This method doesn't care what
# form the data take, it just dumps the raw data to file, showing a progress
# bar if required.

sub _write_data {
  my ( $self, $data, $filename ) = @_;

  my $max        = length $data;
  my $num_chunks = 100;
  my $chunk_size = int( $max / $num_chunks );

  my $pb = $self->config->{no_progress_bars}
         ? 0
         : Term::ProgressBar::Simple->new( {
             name   => 'writing',
             count  => $num_chunks,
             remove => 1,
           } );

  open ( FILE, '>', $filename )
    or Bio::Path::Find::Exception->throw( msg =>  "ERROR: couldn't write output file ($filename): $!" );

  binmode FILE;

  my $written;
  my $offset      = 0;
  my $remaining   = $max;
  while ( $remaining > 0 ) {
    $written = syswrite FILE, $data, $chunk_size, $offset;
    $offset    += $written;
    $remaining -= $written;
    $pb++;
  }

  close FILE;
}

#-------------------------------------------------------------------------------

# build a CSV file with the statistics for all lanes and write it to file

sub _make_stats {
  my ( $self, $lanes ) = @_;

  my $filename;

  # get or build the filename for the output file
  if ( $self->_stats_file ) {
    $self->log->debug('stats attribute specifies a filename');
    $filename = $self->_stats_file;
  }
  else {
    $self->log->debug('stats attribute is a boolean; building a filename');
    $filename = dir( getcwd(), $self->_renamed_id . '.pathfind_stats.csv' );
  }

  # collect the stats for the supplied lanes
  my @stats = (
    $lanes->[0]->stats_headers,
  );

  my $pb = $self->config->{no_progress_bars}
         ? 0
         : Term::ProgressBar::Simple->new( {
             name   => 'collecting stats',
             count  => scalar @$lanes,
             remove => 1,
           } );

  foreach my $lane ( @$lanes ) {
    push @stats, $lane->stats;
    $pb++;
  }

  $self->_write_stats_csv(\@stats, $filename);
}

#-------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

1;
