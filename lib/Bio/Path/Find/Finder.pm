
package Bio::Path::Find::Finder;

# ABSTRACT: find information about sequencing lanes

use v5.10; # required for Type::Params use of "state"

use Moose;
use namespace::autoclean;
use MooseX::StrictConstructor;

use Carp qw( croak carp );
use Path::Class;
use File::Basename;
use Try::Tiny;
use Term::ProgressBar;

use Type::Params qw( compile );
use Types::Standard qw(
  Object
  HashRef
  ArrayRef
  Str
  Int
  slurpy
  Dict
  Optional
);
use Type::Utils qw( enum );
use Bio::Path::Find::Types qw(
  BioPathFindSorter
  IDType
  FileIDType
  QCState
  FileType
);

use Bio::Path::Find::DatabaseManager;
use Bio::Path::Find::Lane;
use Bio::Path::Find::Sorter;

with 'Bio::Path::Find::Role::HasEnvironment',
     'Bio::Path::Find::Role::HasConfig',
     'MooseX::Log::Log4perl';

=head1 CONTACT

path-help@sanger.ac.uk

=cut

#-------------------------------------------------------------------------------
#- public attributes -----------------------------------------------------------
#-------------------------------------------------------------------------------

=head1 ATTRIBUTES

Inherits C<config> and C<environment> from the roles
L<Bio::Path::Find::Role::HasConfig> and
L<Bio::Path::Find::Role::HasEnvironment>.

=attr lane_role

Simple string giving the name of a L<Bio::Path::Find::Role> that should be
applied to the L<Bio::Path::Find::Lane> objects that we build. The Role is used
to adapt the C<Lane> for use with a particular "*find" script, e.g. C<pathfind>
or C<annotationfind>.

If C<lane_role> is not supplied, a default value is generated by taking the
basename of the calling script and using that to look up the role in the
configuration. If there is no mapping for script name in the "C<lane_roles>"
slot in the configuration, an exception is thrown.

=cut

has 'lane_role' => (
  is      => 'ro',
  isa     => Str,
  lazy    => 1,
  builder => '_build_lane_role',
);

sub _build_lane_role {
  my $self = shift;

  my $role = $self->config->{lane_roles}->{ $self->{_script_name} };

  croak "ERROR: couldn't find a lane role for the current script ("
        . $self->{_script_name} . ')'
    if not defined $role;

  return $role;
}

#-------------------------------------------------------------------------------
#- private attributes ----------------------------------------------------------
#-------------------------------------------------------------------------------

# this is only intended for use during testing

has '_script_name' => (
  is      => 'ro',
  isa     => Str,
  default => sub { basename $0 },
);

#---------------------------------------

has '_db_manager' => (
  is      => 'ro',
  isa     => 'Bio::Path::Find::DatabaseManager',
  lazy    => 1,
  builder => '_build_db_manager',
);

sub _build_db_manager {
  my $self = shift;
  return Bio::Path::Find::DatabaseManager->new(
    environment => $self->environment,
    config      => $self->config,
  );
}

#---------------------------------------

has '_sorter' => (
  is      => 'rw',
  isa     => BioPathFindSorter,
  lazy    => 1,
  default => sub {
    my $self = shift;
    Bio::Path::Find::Sorter->new(
      environment => $self->environment,
      config      => $self->config,
    );
  },
);

#-------------------------------------------------------------------------------
#- public methods --------------------------------------------------------------
#-------------------------------------------------------------------------------

sub find_lanes {
  state $check = compile(
    Object,
    slurpy Dict [
      ids      => ArrayRef[Str],
      type     => IDType,
      qc       => Optional[QCState],
      filetype => Optional[FileType],
    ],
  );
  my ( $self, $params ) = $check->(@_);

  $self->log->debug( 'searching with ' . scalar @{ $params->{ids} }
                     . ' IDs of type "' . $params->{type} . q(") );

  # get a list of Bio::Path::Find::Lane objects
  my $lanes = $self->_find_lanes( $params->{ids}, $params->{type} );

  $self->log->debug('found ' . scalar @$lanes . ' lanes');

  # find files for the lanes and filter based on the files and the QC status
  my $filtered_lanes = [];
  LANE: foreach my $lane ( @$lanes ) {

    # ignore this lane if:
    # 1. we've been told to look for a specific QC status, and
    # 2. the lane has a QC status set, and
    # 3. this lane's QC status doesn't match the required status
    if ( defined $params->{qc} and
         defined $lane->row->qc_status and
         $lane->row->qc_status ne $params->{qc} ) {
      $self->log->debug(
        'lane "' . $lane->row->name
        . '" filtered by QC status (actual status is "' . $lane->row->qc_status
        . '"; requiring status "' . $params->{qc} . '")'
      );
      next LANE;
    }

    # return lanes that have a specific type of file
    if ( $params->{filetype} ) {

      $lane->find_files($params->{filetype});

      if ( $lane->has_files ) {
        push @$filtered_lanes, $lane;
      }
      else {
        $self->log->debug('lane "' . $lane->row->name . '" has no files of type "'
                          . $params->{filetype} . '"; filtered out');
      }
    }
    else {
      # we don't care about files; return all lanes
      push @$filtered_lanes, $lane;
    }
  }

  # at this point we have a list of Bio::Path::Find::Lane objects, each of
  # which has a QC status matching the supplied QC value. Each lane has also
  # gone off to look for the files associated with its row in the database

  # sort the lanes based on lane name, etc.
  my $sorted_lanes = $self->_sorter->sort_lanes($filtered_lanes);

  return $sorted_lanes; # array of lane objects
}

#-------------------------------------------------------------------------------
#- private methods -------------------------------------------------------------
#-------------------------------------------------------------------------------

sub _find_lanes {
  my ( $self, $ids, $type ) = @_;

  my @db_names = $self->_db_manager->database_names;

  # set up the progress bar. Check the config for a flag telling us whether we
  # should actually *show* it. If "silent" is set to true, the progress bar
  # object won't actually show anything in the terminal
  my $max = scalar( @db_names ) * scalar( @$ids );
  my $progress_bar = Term::ProgressBar->new( {
    name   => 'finding lanes',
    count  => $max,
    remove => 1,
    silent => $self->config->{no_progress_bars},
  } );
  $progress_bar->minor(0); # ditch the "completion time estimator" character

  # walk over the list of available databases and, for each ID, search for
  # lanes matching the specified ID
  my @lanes;
  my $next_update = 0;
  my $i = 0;
  DB: foreach my $db_name ( @db_names ) {
    $self->log->debug(qq(searching "$db_name"));

    my $database = $self->_db_manager->get_database($db_name);

    ID: foreach my $id ( @$ids ) {
      $self->log->debug( qq(looking for ID "$id") );

      $next_update = $progress_bar->update($i++);

      my $rs = $database->schema->get_lanes_by_id($id, $type);
      next ID unless $rs; # no matching lanes

      $self->log->debug('found ' . $rs->count . ' lanes');

      while ( my $lane_row = $rs->next ) {

        # tell every result (a Bio::Track::Schema::Result object) which
        # database it comes from. We need this later to generate paths on disk
        # for the files associated with each result
        $lane_row->database($database);

        # build a lightweight object to hold all of the data about a particular
        # row
        my $lane;
        try {
          $lane = Bio::Path::Find::Lane->with_traits( $self->lane_role )
                                       ->new( row => $lane_row );
        } catch {
          croak q(ERROR: couldn't apply role ") . $self->lane_role
                . qq(" to lanes: $_);
        };

        push @lanes, $lane;
      }
    }

  }

  $progress_bar->update($max)
    if ( defined $next_update and $max >= $next_update );

  return \@lanes;
}

#-------------------------------------------------------------------------------

__PACKAGE__->meta->make_immutable;

1;

