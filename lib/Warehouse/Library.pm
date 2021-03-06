package Warehouse::Library;

# ABSTRACT: Take in a library name or ssid and fill in the missing data in the file metadata object

=head1 SYNOPSIS

use Warehouse::Library;
my $file = Warehouse::Library->new(
  file_meta_data => $filemetadata,
  _dbh => $warehouse_dbh
  );

$file->populate();

=cut
use Moose;

has 'file_meta_data'   => ( is => 'rw', isa => 'UpdatePipeline::FileMetaData', required => 1 );
has '_dbh'             => ( is => 'rw',                                        required => 1 );


sub populate
{
  my($self) = @_;
  # library name exists, library ssid missing
  $self->_populate_ssid_from_library_tube_name;
  $self->_populate_ssid_from_multiplexed_library_tube_name;
  $self->_populate_ssid_from_aliquot_sample_ssid;
  
  # library ssid exists, library name missing
  $self->_populate_name_from_library_tube_ssid;
  $self->_populate_name_from_multiplexed_library_tube_ssid;
  $self->_populate_name_from_aliquot_sample_ssid;
  1;
}

sub post_populate
{
  my($self) = @_;
  return 1 if(($self->file_meta_data->file_name_without_extension =~ /#/));
  return unless(defined($self->file_meta_data->library_ssid));
  return unless((!defined($self->file_meta_data->fragment_size_from))   ||  (!defined($self->file_meta_data->fragment_size_to)));
  
  # only available on a library tube
  $self->_populate_fragment_size_via_batch_requests_from_library_tube_ssid;
  1;
}


sub _populate_fragment_size_via_batch_requests_from_library_tube_ssid
{
  my($self) = @_;
  if((!defined($self->file_meta_data->fragment_size_from))   ||  (!defined($self->file_meta_data->fragment_size_to)))
  {
    my $library_ssid = $self->file_meta_data->library_ssid;
    
    # very slow query
    my $sql = qq[select requests.fragment_size_from, requests.fragment_size_to from npg_plex_information as npg_plex_information
    left join current_batch_requests as batch_requests on batch_requests.batch_internal_id = npg_plex_information.batch_id
    left join current_requests as requests on requests.uuid = batch_requests.request_uuid
    where npg_plex_information.asset_id = $library_ssid and requests.fragment_size_from is not null and requests.fragment_size_to is not null order by requests.internal_id desc limit 1;];
    my $sth = $self->_dbh->prepare($sql);
    $sth->execute;
    my @library_warehouse_details  = $sth->fetchrow_array;
    if(@library_warehouse_details > 0)
    {
      $self->file_meta_data->fragment_size_from($library_warehouse_details[0]);
      $self->file_meta_data->fragment_size_to($library_warehouse_details[1]);
    }
  }
} 

sub _populate_ssid_from_library_tube_name
{
  my($self) = @_;
  if(defined($self->file_meta_data->library_name) && ! defined($self->file_meta_data->library_ssid)  )
  {
    my $library_name = $self->file_meta_data->library_name;
    my $sql = qq[select internal_id as library_ssid from current_library_tubes where name = "$library_name" limit 1;];
    my $sth = $self->_dbh->prepare($sql);
    $sth->execute;
    my @library_warehouse_details  = $sth->fetchrow_array;
    if(@library_warehouse_details > 0)
    {
      $self->file_meta_data->library_ssid($library_warehouse_details[0]);
    }
  }
}

sub _populate_ssid_from_multiplexed_library_tube_name
{
  my($self) = @_;
  if(defined($self->file_meta_data->library_name) && ! defined($self->file_meta_data->library_ssid)  )
  {
    my $library_name = $self->file_meta_data->library_name;
    my $sql = qq[select internal_id as library_ssid from current_multiplexed_library_tubes where name = "$library_name" limit 1;];
    my $sth = $self->_dbh->prepare($sql);
    $sth->execute;
    my @library_warehouse_details  = $sth->fetchrow_array;
    if(@library_warehouse_details > 0)
    {
      $self->file_meta_data->library_ssid($library_warehouse_details[0]);
    }
  }
}

sub _populate_ssid_from_aliquot_sample_ssid
{
  my($self) = @_;
  if(defined($self->file_meta_data->sample_ssid) && ! defined($self->file_meta_data->library_ssid)  )
  {
    my $sample_ssid = $self->file_meta_data->sample_ssid;
    my $sql = qq[select library_internal_id from current_aliquots where receptacle_type = 'multiplexed_library_tube' and sample_internal_id = $sample_ssid limit 1;];
    my $sth = $self->_dbh->prepare($sql);
    $sth->execute;
    my @library_warehouse_details  = $sth->fetchrow_array;
    if(@library_warehouse_details > 0)
    {
      $self->file_meta_data->library_ssid($library_warehouse_details[0]);
    }
  }
}



sub _populate_name_from_library_tube_ssid
{
  my($self) = @_;
  if(defined($self->file_meta_data->library_ssid) && ! defined($self->file_meta_data->library_name)  )
  {
    my $library_ssid = $self->file_meta_data->library_ssid;
    my $sql = qq[select name as library_name from current_library_tubes where internal_id = "$library_ssid" limit 1;];
    my $sth = $self->_dbh->prepare($sql);
    $sth->execute;
    my @library_warehouse_details  = $sth->fetchrow_array;
    if(@library_warehouse_details > 0)
    {
      $self->file_meta_data->library_name($library_warehouse_details[0]);
    }
  }
}

sub _populate_name_from_multiplexed_library_tube_ssid
{
  my($self) = @_;
  if(defined($self->file_meta_data->library_ssid) && ! defined($self->file_meta_data->library_name)  )
  {
    my $library_ssid = $self->file_meta_data->library_ssid;
    my $sql = qq[select name as library_name from current_multiplexed_library_tubes where internal_id = "$library_ssid" limit 1;];
    my $sth = $self->_dbh->prepare($sql);
    $sth->execute;
    my @library_warehouse_details  = $sth->fetchrow_array;
    if(@library_warehouse_details > 0)
    {
      $self->file_meta_data->library_name($library_warehouse_details[0]);
    }
  }
}

sub _populate_name_from_aliquot_sample_ssid
{
  my($self) = @_;
  if(defined($self->file_meta_data->sample_ssid) && ! defined($self->file_meta_data->library_name)  )
  {
    my $sample_ssid = $self->file_meta_data->sample_ssid;
    my $sql = qq[select library_internal_id from current_aliquots where receptacle_type = 'multiplexed_library_tube' and sample_internal_id = $sample_ssid limit 1;];
    my $sth = $self->_dbh->prepare($sql);
    $sth->execute;
    my @library_warehouse_details  = $sth->fetchrow_array;
    if(@library_warehouse_details > 0)
    {
      $self->file_meta_data->library_name($library_warehouse_details[0]);
    }
  }
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;
