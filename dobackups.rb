require_relative 'snapshot.rb'

s = Snapshot.new
puts s.create_snapshots(true)
puts s.delete_expired_snapshots
puts s.create_images(true)
puts s.delete_expired_images
#puts s.copy_image("ami-5af0c31f", Snapshot::AWSCONFIG[:default_region], Snapshot::AWSCONFIG[:backup_region], "Helios backup Jan 2014", "Backup for " + Time.now.to_s + " - created by SDK")
