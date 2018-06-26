require 'net/http'
require 'rexml/document'
require 'rexml/xpath'
require 'rexml/element'
require 'dimensions'

require './common.rb'

config = Config.read do |config|
  config["nodes"]=["http://localhost:8080/geoserver/"]
  config["layer"]="a layer with global extent"
end

nodes = config["nodes"].map {|uri| URI(uri)}
node1 = nodes[0]
node2 = nodes[-1]

layer = config["layer"]

# Check that the layer exists in REST and has the default EPSG:4326 quadtree gridset

gridset = "EPSG:4326"

nodes.each do |base|
  raise "layer #{layer} does not have gridset #{gridset}" if rest_get(base+("gwc/rest/layers/"+layer+".xml")).root.elements["/GeoServerLayer/gridSubsets/gridSubset/gridSetName[text()='#{gridset}']"].nil?
end

# Check that we can make a tile request and get a PNG

nodes.each do |base|
  wmts_gettile(base, layer, gridset, "image/png", 3,2,3) do |response|
    response.value
    dim =  Dimensions::Reader.new
    dim << response.body
    raise "expected 256x256 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==256 and dim.height==256 and dim.type==:png)
  end
end


puts "PASS"
