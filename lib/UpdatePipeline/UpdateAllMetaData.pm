package UpdatePipeline::UpdateAllMetaData;

# ABSTRACT: Take in a list of study names, and a VRTracking database handle and update/create where IRODs differs to the tracking database

=head1 SYNOPSIS

my $pipeline = UpdatePipeline::UpdateAllMetaData->new(study_names => \@study_names, _vrtrack => $self->_vrtrack);
$pipeline->update();

=cut

use Moose;
use UpdatePipeline::IRODS;
use UpdatePipeline::VRTrack::LaneMetaData;
use UpdatePipeline::UpdateLaneMetaData;
use UpdatePipeline::VRTrack::Project;
use UpdatePipeline::VRTrack::Sample;
use UpdatePipeline::VRTrack::Library;
use UpdatePipeline::VRTrack::Lane;
use UpdatePipeline::VRTrack::File;
use UpdatePipeline::VRTrack::Study;
use UpdatePipeline::ExceptionHandler;
use Pathogens::ConfigSettings;
extends 'UpdatePipeline::CommonMetaDataManipulation';
with 'UpdatePipeline::CommonDatabaseSetup';
               
has '_exception_handler'    => ( is => 'rw', lazy_build => 1,            isa => 'UpdatePipeline::ExceptionHandler' );
has '_config_settings'      => ( is => 'rw', lazy_build => 1,            isa => 'HashRef' );
has 'update_if_changed'     => ( is => 'rw', default    => 0,            isa => 'Bool');
has 'dont_use_warehouse'    => ( is => 'ro', default    => 0,            isa => 'Bool');
has 'use_supplier_name'     => ( is => 'ro', default    => 0,            isa => 'Bool');
has 'override_md5'          => ( is => 'ro', default    => 0,            isa => 'Bool');
has 'add_raw_reads'         => ( is => 'ro', default    => 0,            isa => 'Bool');
has 'specific_run_id'       => ( is => 'ro', default    => 0,            isa => 'Int');                      
has 'minimum_run_id'        => ( is => 'rw', default    => 1,            isa => 'Int' );
has 'environment'           => ( is => 'rw', default    => 'production', isa => 'Str');
has 'common_name_required'  => ( is => 'rw', default    => 1,            isa => 'Bool');
has 'taxon_id'              => ( is => 'rw', default    => 0,            isa => 'Int' );
has 'species_name'          => ( is => 'ro',                             isa => 'Maybe[Str]' );
has 'vrtrack_lanes'         => ( is => 'ro',                             isa => 'Maybe[HashRef]' );
has 'bin_directory'         => (isa => 'Str', is => 'rw', default => '/software/irods/icommands/bin/');


sub _build__config_settings
{
   my ($self) = @_;
   \%{Pathogens::ConfigSettings->new(environment => $self->environment, filename => 'config.yml')->settings()};
}

sub _build__exception_handler
{
  my ($self) = @_;
  UpdatePipeline::ExceptionHandler->new( _vrtrack => $self->_vrtrack, minimum_run_id => $self->minimum_run_id, update_if_changed => $self->update_if_changed );
}


sub update
{
  my ($self) = @_;

  $self->_set_database_auto_reconnect;
  my %current_lane_names;
  my $num_lanes_in_vrtrack = $self->vrtrack_lanes ? keys %{$self->vrtrack_lanes} : 0;
  for my $file_metadata (@{$self->_files_metadata}) {
    $current_lane_names{$file_metadata->file_name_without_extension} = 1;
    if ($self->taxon_id && defined $self->species_name) {
    	$file_metadata->sample_common_name($self->species_name);
    }
    eval {
      if(UpdatePipeline::UpdateLaneMetaData->new(
          lane_meta_data => $self->get_lane_metadata($file_metadata->file_name_without_extension),
          file_meta_data => $file_metadata,
          common_name_required => $self->common_name_required,
          check_file_md5s => $self->override_md5,
          use_supplier_name => $self->use_supplier_name
          )->update_required
        )
      {
          $self->_post_populate_file_metadata($file_metadata) unless($self->dont_use_warehouse);
		  my $filter_pending = ( !$self->no_pending_lanes || ( $self->no_pending_lanes && defined $file_metadata->lane_manual_qc && $file_metadata->lane_manual_qc ne 'pending' ) );
		  my $filter_id_run = ( !$self->specific_run_id || ( $self->specific_run_id && defined $file_metadata->id_run && $self->specific_run_id == $file_metadata->id_run));
		  my $filter_min_run = ( !$self->specific_min_run || ( $self->specific_min_run && defined $file_metadata->id_run && $self->specific_min_run < $file_metadata->id_run));
          $self->_update_lane($file_metadata) unless ( !$filter_pending  || !$filter_id_run || !$filter_min_run );
      }
    };
    
    
    if(my $exception = Exception::Class->caught())
    {
      $self->_exception_handler->add_exception($exception,$file_metadata->file_name_without_extension);
    }
    if ( $self->vrtrack_lanes && $self->vrtrack_lanes->{$file_metadata->file_name_without_extension} ) {
		delete $self->vrtrack_lanes->{$file_metadata->file_name_without_extension};
	}	
  }
  if ( $self->vrtrack_lanes && keys %{$self->vrtrack_lanes} > 0 && scalar @{$self->_files_metadata} > 0 && $self->_check_irods_is_up ) {
	  $self->_withdraw_lanes;
  }
  if ( $num_lanes_in_vrtrack <= keys %current_lane_names ) {
      $self->_unwithdraw_lanes(\%current_lane_names);
  }
  $self->_exception_handler->print_report($self->verbose_output);
  1;
}

sub _update_lane
{
  my ($self, $file_metadata) = @_;
  eval {
    my $vproject = UpdatePipeline::VRTrack::Project->new(name => $file_metadata->study_name, external_id => $file_metadata->study_ssid, data_access_group => $file_metadata->data_access_group,  _vrtrack => $self->_vrtrack)->vr_project();
    if(defined($file_metadata->study_accession_number))
    {
      my $vstudy   = UpdatePipeline::VRTrack::Study->new(accession => $file_metadata->study_accession_number, _vr_project => $vproject)->vr_study();
      $vproject->update;
    }
    
    my $vr_sample = UpdatePipeline::VRTrack::Sample->new(
      common_name_required => $self->common_name_required,
      name => $file_metadata->sample_name,  
      external_id => $file_metadata->sample_ssid, 
      common_name => $file_metadata->sample_common_name, 
      accession => $file_metadata->sample_accession_number,
      supplier_name => $file_metadata->supplier_name,
      use_supplier_name => $self->use_supplier_name,
      public_name => $file_metadata->public_name,
      taxon_id => $self->taxon_id,
      _vrtrack => $self->_vrtrack,
      _vr_project => $vproject)->vr_sample();
      
    my $vr_library = UpdatePipeline::VRTrack::Library->new(
      name => $file_metadata->library_name,
      external_id        => $file_metadata->library_ssid,
      fragment_size_from => $file_metadata->fragment_size_from,
      fragment_size_to   => $file_metadata->fragment_size_to,
      _vrtrack           => $self->_vrtrack,
      _vr_sample         => $vr_sample)->vr_library();

    my $vr_lane = UpdatePipeline::VRTrack::Lane->new(
      name          => $file_metadata->file_name_without_extension,
      paired        => $file_metadata->lane_is_paired_read,
      npg_qc_status => $file_metadata->lane_manual_qc,
      raw_reads     => $file_metadata->total_reads, 
      add_raw_reads => $self->add_raw_reads,
      ebi_run_acc   => $file_metadata->ebi_run_acc,
	  run_date      => $file_metadata->run_date,
      _vrtrack      => $self->_vrtrack,
      _vr_library   => $vr_library)->vr_lane();


    UpdatePipeline::VRTrack::File->new(
      name         => $file_metadata->file_name,
      file_type    => $file_metadata->file_type_number($file_metadata->file_type), 
      md5          => $file_metadata->file_md5 , 
      override_md5 => $self->override_md5, 
      reference    => $file_metadata->reference,
      _vrtrack     => $self->_vrtrack,
      _vr_lane     => $vr_lane)->vr_file();
      
    if(defined($file_metadata->mate_file_name))
    {
      UpdatePipeline::VRTrack::File->new(name => $file_metadata->mate_file_name ,file_type => $file_metadata->mate_file_type_number($file_metadata->mate_file_type), md5 => $file_metadata->mate_file_md5 ,_vrtrack => $self->_vrtrack,_vr_lane => $vr_lane)->vr_file();
    }
  };
  if(my $exception = Exception::Class->caught())
  {
    $self->_exception_handler->add_exception($exception, $file_metadata->file_name_without_extension);
  }
}

sub _post_populate_file_metadata
{
  my ($self, $file_metadata) = @_;
  Warehouse::FileMetaDataPopulation->new(file_meta_data => $file_metadata, _dbh => $self->_warehouse_dbh)->post_populate();
}

sub _withdraw_lanes
{
	#Subroutine that withdraws lanes that have been deleted from iRODS, but remain in the database.
	#This can only called if the -wdr flag is set on the command lane explicitly.
	my ($self) = @_;
  	foreach my $lane ( keys %{$self->vrtrack_lanes} ) {
		my $lane_to_withdraw = VRTrack::Lane->new($self->_vrtrack, $self->vrtrack_lanes->{$lane});
		$lane_to_withdraw->is_withdrawn(1);
		$lane_to_withdraw->update;	
		print "The lane $lane has been withdrawn as it has been deleted from iRODS\n";
	}
}

sub _unwithdraw_lanes
{
    my ($self, $current_lane_names) = @_;
    foreach my $lane ( keys %{$current_lane_names} ) {
        my $lane_to_unwithdraw = VRTrack::Lane->new_by_name($self->_vrtrack, $lane) || return;
        if ($lane_to_unwithdraw->is_withdrawn && ! $lane_to_unwithdraw->is_manually_withdrawn) {
            $lane_to_unwithdraw->is_withdrawn(0);
            $lane_to_unwithdraw->update;  
            print "The lane $lane has been unwithdrawn as it has reappeared in iRODS\n";
        }
    }
}

#
# Just to double check iRODS in case it went down part way through loading the file metadata
#
sub _check_irods_is_up
{
	my ($self) = @_;
	
	my $cmd = $self->bin_directory . "ils /seq 2>&1 ";
  open(my $irods_ils_fh, '-|', $cmd);
  while(<$irods_ils_fh>)
  {
    if(m/ERROR/g )
    {
      return 0;
    }
  }
  return 1;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

