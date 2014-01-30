require 'rubygems'
require 'nokogiri'
require 'AWS'
require 'aws/ec2'
require 'aws/s3'
require 'active_support/core_ext'
require 'time'
require 'yaml'

#creates snapshot of AMI
#creates snapshots, tags with expiration date, deletes them when expired,
#copies them to another region for backup
class Snapshot
  ACCESS_KEY = ""
  SECRET_KEY = ""
  DEFAULT_REGION = "us-west-1"
  BACKUP_REGION = "us-east-1"
  SNAPSHOTS_EXPIRE_IN = 7 #in days
  ayml = HashWithIndifferentAccess.new(YAML.load_file(File.expand_path('../aws.yml', __FILE__)))
  AWSCONFIG = ayml.inject({}){|memo,(k,v)| memo[k.to_sym] = v; memo} #symbolize keys

  def initialize
    AWS.config(access_key_id: AWSCONFIG[:access_key], secret_access_key: AWSCONFIG[:secret_key], region: AWSCONFIG[:default_region])
  end
  
  #create snapshots and copy to another region if isCopy = true
  def create_snapshots(isCopy)
    ec2 = AWS::EC2.new.client

    #get all volumes tagged as "backup"
    volumes = ec2.describe_volumes(:filters => [:name => 'tag-key', :values => ['backup']])
    snapshots = []

    #loop thru and create snapshots for all these volumes
    if volumes      
      volumes.data[:volume_set].each do |v|
        name = get_tagvalue(v, "Name")
        snap = ec2.create_snapshot(:volume_id => v[:volume_id], :description => "Backup for " + Time.now.to_s + " - created by SDK")
        if snap
          snapshots << snap.data
          #add name tag
          ec2.create_tags(:resources => [snap.data[:snapshot_id]], :tags => [{:key => "Name", :value => name + " backup"}])

          #now copy snapshots to another region
          if isCopy
            copy_snapshot(snap.data[:snapshot_id], AWSCONFIG[:default_region], AWSCONFIG[:backup_region], 
              name + " backup", "Backup for " + Time.now.to_s + " - created by SDK")
          end
        end
      end
    end

    return snapshots
  end

  #copy/backup snapshot from one region to another
  def copy_snapshot(source_snapshot_id, source_region, target_region, name, description)
    ec2 = AWS::EC2.new(:region => target_region).client
    snap = ec2.copy_snapshot(:source_region => source_region, :source_snapshot_id => source_snapshot_id,
      :description => description)
    if snap
      #add expiry tag if snapshots_expire_in setting > 0. if 0 they never expire
      if SNAPSHOTS_EXPIRE_IN > 0
        ec2.create_tags(:resources => [snap.data[:snapshot_id]], :tags => [{:key => "expiring", :value =>
            (Time.now + SNAPSHOTS_EXPIRE_IN.to_i.days).to_s}, {:key => "Name", :value => name}])
      end
      return snap.data[:snapshot_id]
    end

    return ""
  end

  #delete snapshots with expiring tags that are in the past
  def delete_expired_snapshots(region = AWSCONFIG[:default_region])
    #find snapshots with tags of expiring and less than today's date
    ec2 = AWS::EC2.new(:region => region).client
    snapshots = ec2.describe_snapshots(:owner_ids => ["self"], :filters => [:name => 'tag-key', :values => ['expiring']])
    deleted_snapshots = []

    #loop thru to see if they are in the past
    if snapshots
      snapshots.data[:snapshot_set].each do |s|
        expdate = get_tagvalue(s, "expiring")
        if expdate.length > 0
          begin
            expdate = Time.parse(expdate)
            if expdate < Time.now
              #expired in the past so delete
              deleted_snapshots << s
              ec2.delete_snapshot(:snapshot_id => s[:snapshot_id])
            end
          rescue => e
          #error parsing - do something or nothing
          end
        end
      end
    end

    return deleted_snapshots
  end

  #create image from instance and copy to another region if isCopy = true
  def create_images(isCopy)
    ec2 = AWS::EC2.new.client
    instances = ec2.describe_instances(:filters => [:name => 'tag-key', :values => ['backup']])
    images = []
    if instances
      if instances.data[:reservation_set].count > 0
        instances.data[:reservation_set].each do |rs|
           rs[:instances_set].each do |i|
           #get name of instance
            name = get_tagvalue(i, "Name") + " backup at " + Time.now.to_s.gsub(":", "-")
            image = ec2.create_image(:instance_id => i[:instance_id], 
              :name => name,
              :description => "Created - " + Time.now.to_s + " - created by SDK", :no_reboot => true)
            images << image if image
            if (isCopy)
              copy_image(i[:image_id], AWSCONFIG[:default_region], AWSCONFIG[:backup_region], 
                name, "Backup for " + Time.now.to_s + " - created by SDK")
            end
          end
        end
      end
    end

    return images
  end

  #copy/backup image from one region to another
  def copy_image(source_image_id, source_region, target_region, name, description)
    ec2 = AWS::EC2.new(:region => target_region).client
    image = ec2.copy_image(:source_region => source_region, :source_image_id => source_image_id,
      :name => name, :description => description)
    if image
      #add expiry tag if snapshots_expire_in setting > 0. if 0 they never expire
      if SNAPSHOTS_EXPIRE_IN > 0
        ec2.create_tags(:resources => [image.data[:image_id]], :tags => [{:key => "expiring", :value =>
            (Time.now + SNAPSHOTS_EXPIRE_IN.to_i.days).to_s}, {:key => "Name", :value => name}])
      end
      return image.data[:image_id]
    end

    return ""
  end

  #delete images with expiring tags that are in the past
  def delete_expired_images(region = AWSCONFIG[:default_region])
    #find images with tags of expiring and less than today's date
    ec2 = AWS::EC2.new(:region => region).client
    images = ec2.describe_images(:owners => ["self"], :filters => [:name => 'tag-key', :values => ['expiring']])
    deleted_images = []

    #loop thru to see if they are in the past
    if images
      images.data[:images_set].each do |i|
        expdate = get_tagvalue(i, "expiring")
        if expdate.length > 0
          begin
            expdate = Time.parse(tags.value)
            if expdate < Time.now
              #expired in the past so delete
              deleted_images << i
              #delete associated snapshots first
              i[:block_device_mapping].each do |dev|
                ec2.delete_snapshot(:snapshot_id => dev[:ebs][:snapshot_id])
              end
              ec2.deregister_image(:image_id => i[:image_id])
            end
          rescue => e
          #error parsing - do something or nothing
          end
        end
      end
    end

    return deleted_images
  end
  
  #gets value of a tag key from the object. object has to expose [:tag_set]
  def get_tagvalue(object, tagkey)
    value = ""
    if object[:tag_set]
      object[:tag_set].each do |tag|
        if tag[:key] == tagkey
          value = tag[:value]
          break
        end
      end
    end
    
    value
  end

end

#s = Snapshot.new
#s.create_snapshots(false)
#puts s.copy_image("ami-5af0c31f", Snapshot::AWSCONFIG[:default_region], Snapshot::AWSCONFIG[:backup_region], "Helios backup Jan 2014", "Backup for " + Time.now.to_s + " - created by SDK")
#s.create_snapshots(true)
