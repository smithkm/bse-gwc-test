require 'net/http'
require 'rexml/document'
require 'rexml/xpath'
require 'rexml/element'
require 'dimensions'
require 'yaml'
require 'fileutils'

require './common.rb'

class Config
  def initialize(config, needed_config_values)
    @config = config
    @needed_config_values = needed_config_values
  end

  def []=(key, example)
    if @config.has_key? key
      return @config[key]
    else
      @config[key]=example
      @needed_config_values<< key
    end
  end
  
  def self.read(config_file = 'config.yml')
    FileUtils.touch(config_file)

    config = YAML::load_file(config_file)
    config={} unless config.respond_to? :has_key?
  
    needed_config_values = []

    yield Config.new(config, needed_config_values)
    
    unless needed_config_values.empty?
      $stderr.puts "#{config_file} missing config values: #{needed_config_values}"
      File.write(config_file, config.to_yaml)
      raise "Please check/fill in values before re-running"
    end
    
    return config
  end
end

config = Config.read do |config|
  config["xstream_class_remove"]=false
  config["nodes"]=["http://localhost:8080/geoserver/"]
  config["layer"]="a layer with global extent"
  config["aws_key"]="Enter AWS access key here"
  config["aws_secret"]="Enter AWS secret key here"
  config["s3_blobstore_bucket"]="Enter bucket for S3 Blob Store"
  config["s3_blobstore_prefix"]="Enter prefix for S3 Blob Store"
end

$xstream_class_remove = config["xstream_class_remove"]

nodes = config["nodes"].map {|uri| URI(uri)}
node1 = nodes[0]
node2 = nodes[-1]

layer = config["layer"]

gridset = "EPSG:4326"

blobstore = "testBlobStore"

blobstore_body = <<EOS
<?xml version="1.0" encoding="UTF-8"?>
<S3BlobStore default="false">
  <id>#{blobstore}</id>
  <enabled>true</enabled>
  <bucket>#{config["s3_blobstore_bucket"]}</bucket>
  <prefix>#{config["s3_blobstore_prefix"]}</prefix>
  <awsAccessKey>#{config["aws_key"]}</awsAccessKey>
  <awsSecretKey>#{config["aws_secret"]}</awsSecretKey>
  <maxConnections>50</maxConnections>
  <useHTTPS>true</useHTTPS>
  <useGzip>true</useGzip>
 </S3BlobStore>
EOS

def assertCacheStatus(response, status)
  raise "expected cache #{status}" unless response["geowebcache-cache-result"]==status.to_s.upcase
end

def assertImage(response, type, width, height=width)
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected #{width}x#{height} #{type} but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==width and dim.height==height and dim.type==type)
end


# Make sure we are ready for the test

nodes.each do |base|
  # truncate the layer
  begin
    rest_mass_truncate(base, layer)
  rescue Net::HTTPFatalError,Net::HTTPServerException
    puts "Pre-test Truncate failed"
  end
end
nodes.each do |base|
  # set to use default blob store
  rest_update(base+("gwc/rest/layers/"+layer)) do |doc|
    e = doc.root.elements["//blobStoreId"]
    puts doc
    e.remove unless e.nil?
    doc
  end
end
nodes.each do |base|
  # truncate the layer again
  begin
    rest_mass_truncate(base, layer)
  rescue Net::HTTPFatalError,Net::HTTPServerException
    puts "Pre-test Truncate failed"
  end
end
nodes.each do |base|
  begin
    rest_delete(base+("gwc/rest/blobstores/"+blobstore))
  rescue Net::HTTPServerException
    puts "Pre-test blobstore delete failed, probably due to not existing, this is probably fine"
  end
end

# Add store

rest_add(node1+("gwc/rest/blobstores/"+blobstore), blobstore_body)

wmts_gettile(node1, layer, gridset, "image/png", 2,1,0) do |response|
  response.value
  assertCacheStatus(response, :miss)
  assertImage(response, :png, 256)
end

wmts_gettile(node2, layer, gridset, "image/png", 2,1,0) do |response|
  response.value
  assertCacheStatus(response, :miss)
  assertImage(response, :png, 256)
end

# Check that the store was added

nodes.each do |base|
  raise "#{blobstore} not added" if rest_get(base+("gwc/rest/blobstores")).root.elements["/blobStores/blobStore/name[text()='#{blobstore}']"].nil?
  raise "#{blobstore} not added" if rest_get(base+("gwc/rest/blobstores/"+blobstore)).root.elements["/FileBlobStore/id[text()='#{blobstore}']"].nil?
end

puts "PASS"
