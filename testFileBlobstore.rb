require 'net/http'
require 'rexml/document'
require 'rexml/xpath'
require 'rexml/element'
require 'dimensions'

require './common.rb'

config = Config.read do |config|
  config["xstream_class_remove"]=false
  config["nodes"]=["http://localhost:8080/geoserver/"]
  config["layer"]="a layer with global extent"
  config["file_blobStore_path"]="/tmp/testBlobStore"
  config["cache_deleted_when_blobstore_changes"]=false
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
<FileBlobStore default="false">
  <id>#{blobstore}</id>
  <enabled>true</enabled>
  <baseDirectory>#{config["file_blobStore_path"]}</baseDirectory>
  <fileSystemBlockSize>4096</fileSystemBlockSize>
 </FileBlobStore>
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


wmts_gettile(node1, layer, gridset, "image/png", 2,1,2) do |response|
  response.value
  assertCacheStatus(response, :miss)
  assertImage(response, :png, 256)
end

wmts_gettile(node2, layer, gridset, "image/png", 2,1,2) do |response|
  response.value
  assertCacheStatus(response, :hit)
  assertImage(response, :png, 256)
end

wmts_gettile(node2, layer, gridset, "image/png", 2,1,3) do |response|
  response.value
  assertCacheStatus(response, :miss)
  assertImage(response, :png, 256)
end

# Add store

rest_add(node1+("gwc/rest/blobstores/"+blobstore), blobstore_body)

# Check that the store was added

nodes.each do |base|
  raise "#{blobstore} not added" if rest_get(base+("gwc/rest/blobstores")).root.elements["/blobStores/blobStore/name[text()='#{blobstore}']"].nil?
  raise "#{blobstore} not added" if rest_get(base+("gwc/rest/blobstores/"+blobstore)).root.elements["/FileBlobStore/id[text()='#{blobstore}']"].nil?
end

# Set layer to use gridset
rest_update(node1+("gwc/rest/layers/"+layer)) do |doc|
  doc.root.add_element(REXML::Element.new("blobStoreId")).text=blobstore
  doc
end

wmts_gettile(node1, layer, gridset, "image/png", 2,1,2) do |response|
  response.value
  assertCacheStatus(response, :miss)
  assertImage(response, :png, 256)
end

wmts_gettile(node2, layer, gridset, "image/png", 2,1,2) do |response|
  response.value
  assertCacheStatus(response, :hit)
  assertImage(response, :png, 256)
end

wmts_gettile(node2, layer, gridset, "image/png", 2,1,3) do |response|
  response.value
  assertCacheStatus(response, :miss)
  assertImage(response, :png, 256)
end

if config["cache_deleted_when_blobstore_changes"]
  # Revert to default
  
  rest_update(node1+("gwc/rest/layers/"+layer)) do |doc|
    e = doc.root.elements["//blobStoreId"]
    e.remove unless e.nil?
    doc
  end
  
  wmts_gettile(node1, layer, gridset, "image/png", 2,1,2) do |response|
    response.value
    assertCacheStatus(response, :miss)
    assertImage(response, :png, 256)
  end
  
  wmts_gettile(node2, layer, gridset, "image/png", 2,1,2) do |response|
    response.value
    assertCacheStatus(response, :hit)
    assertImage(response, :png, 256)
  end
  
  wmts_gettile(node2, layer, gridset, "image/png", 2,1,3) do |response|
    response.value
    assertCacheStatus(response, :miss)
    assertImage(response, :png, 256)
  end
end

puts "PASS"
