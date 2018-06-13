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
  config["manual_truncate_on_gridset_change"]=false
end

$xstream_class_remove = config["xstream_class_remove"]
$manual_truncate_on_gridset_change = config["manual_truncate_on_gridset_change"]

nodes = config["nodes"].map {|uri| URI(uri)}
node1 = nodes[0]
node2 = nodes[-1]

layer = config["layer"]

gridset = "EPSG:2163"
gridset_body = <<EOS
<gridSet>
  <name>EPSG:2163</name>
  <srs>
    <number>2163</number>
  </srs>
  <extent>
    <coords>
      <double>-2495667.977678598</double>
      <double>-2223677.196231552</double>
      <double>3291070.6104286816</double>
      <double>959189.3312465074</double>
    </coords>
  </extent>
  <alignTopLeft>false</alignTopLeft>
  <scaleDenominators>
    <double>2.5E7</double>
    <double>1000000.0</double>
    <double>100000.0</double>
    <double>25000.0</double>
  </scaleDenominators>
  <metersPerUnit>1.0</metersPerUnit>
  <pixelSize>2.8E-4</pixelSize>
  <scaleNames>
    <string>EPSG:2163:0</string>
    <string>EPSG:2163:1</string>
    <string>EPSG:2163:2</string>
    <string>EPSG:2163:3</string>
  </scaleNames>
  <tileHeight>200</tileHeight>
  <tileWidth>200</tileWidth>
  <yCoordinateFirst>false</yCoordinateFirst>
</gridSet>
EOS

# Make sure we are ready for the test

nodes.each do |base|
  begin
    rest_mass_truncate(base, layer)
  rescue Net::HTTPFatalError,Net::HTTPServerException
    puts "Pre-test Truncate failed, probably due to gridset not existing, this is probably fine"
  end
  rest_update(base+("gwc/rest/layers/"+layer)) do |doc|
    e = doc.root.elements["//gridSubset/[gridSetName[text()='#{gridset}']]"]
    e.delete unless e.nil?
    doc
  end
  begin
    rest_delete(base+("gwc/rest/gridsets/"+gridset))
  rescue Net::HTTPServerException
    puts "Pre-test gridset delete failed, probably due to layergridset not existing, this is probably fine"
  end
end

# Add gridset

rest_add(node1+("gwc/rest/gridsets/"+gridset), gridset_body)

# Check that the gridset was added

raise "gridset #{gridset} not added to local layer catalog" if rest_get(node1+("gwc/rest/gridsets")).root.elements["/gridSets/gridSet/name[text()='#{gridset}']"].nil?
raise "gridset #{gridset} not added to remote layer catalog" if rest_get(node2+("gwc/rest/gridsets")).root.elements["/gridSets/gridSet/name[text()='#{gridset}']"].nil?

raise "gridset #{gridset} not added to local layer catalog" if rest_get(node1+("gwc/rest/gridsets/"+gridset)).root.elements["/gridSet/name[text()='#{gridset}']"].nil?
raise "gridset #{gridset} not added to remote layer catalog" if rest_get(node2+("gwc/rest/gridsets/"+gridset)).root.elements["/gridSet/name[text()='#{gridset}']"].nil?


# Add gridset to layer

rest_update(node1+("gwc/rest/layers/"+layer)) do |doc|
  doc.root.elements["//gridSubsets"].add_element(REXML::Element.new("gridSubset")).add_element("gridSetName").text=gridset
  doc
end

# Check that gridset was added to layer via REST

raise "gridset #{gridset} not added to local layer #{layer}" if rest_get(node1+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/gridSubsets/gridSubset/gridSetName[text()='#{gridset}']"].nil?
raise "gridset #{gridset} not added to remote layer #{layer}" if rest_get(node2+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/gridSubsets/gridSubset/gridSetName[text()='#{gridset}']"].nil?

# Check that gridset was added to layer via WMTS GetCapabilities

nodes.each do |base|
  wmts_getcap(base) do |response|
    response.value
    doc = REXML::Document.new response.body
    raise "gridset #{gridset} not in WMTS capabilities" if doc.root.elements["/Capabilities/Contents/TileMatrixSet/ows:Identifier[text()='#{gridset}']"].nil?
    doc.root.elements.each("/Capabilities/Contents/TileMatrixSet[ows:Identifier[text()='#{gridset}']]TileMatrix") do |matrix|
      puts matrix
    end
  end
end

# Check that we get correct behaviour for  WMTS GetTile

wmts_gettile(node1, layer, gridset, "image/png", 2,1,0) do |response|
  p response.body
  response.value
  raise "expected cache miss" unless response["geowebcache-cache-result"]=="MISS"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 200x200 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==200 and dim.height==200 and dim.type==:png)
end

wmts_gettile(node2, layer, gridset, "image/png", 2,1,0) do |response|
  response.value
  raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 200x200 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==200 and dim.height==200 and dim.type==:png)
end

# Get a different tile
wmts_gettile(node2, layer, gridset, "image/png", 2,2,1) do |response|
  response.value
  raise "expected cache miss" unless response["geowebcache-cache-result"]=="MISS"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 200x200 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==200 and dim.height==200 and dim.type==:png)
end

wmts_gettile(node1, layer, gridset, "image/png", 2,2,1) do |response|
  response.value
  raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 200x200 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==200 and dim.height==200 and dim.type==:png)
end

rest_update(node1+("gwc/rest/gridsets/"+gridset)) do |doc|
  doc.root.elements["//tileHeight"].text="256"
  doc.root.elements["//tileWidth"].text="256"
  doc
end

nodes.each do |base|
  raise "gridset #{gridset} not updated on #{base}" if rest_get(base+("gwc/rest/gridsets/"+gridset)).root.elements["/gridSet/tileHeight[text()='256']"].nil?
  raise "gridset #{gridset} not updated on #{base}" if rest_get(base+("gwc/rest/gridsets/"+gridset)).root.elements["/gridSet/tileWidth[text()='256']"].nil?  
end

if $manual_truncate_on_gridset_change
  puts "Doing a manual truncate after gridset change.  Need to fix GWC to do this automatically."
  rest_mass_truncate(node1, layer)
end

# Get tiles again.  Dimensions should reflect new size and misses should indicate the cache was truncated
wmts_gettile(node1, layer, gridset, "image/png", 2,1,0) do |response|
  response.value
  raise "expected cache miss" unless response["geowebcache-cache-result"]=="MISS"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 256x256 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==256 and dim.height==256 and dim.type==:png)
end

wmts_gettile(node2, layer, gridset, "image/png", 2,1,0) do |response|
  response.value
  raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 256x256 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==256 and dim.height==256 and dim.type==:png)
end

# Get a different tile starting with second node
wmts_gettile(node2, layer, gridset, "image/png", 2,2,1) do |response|
  response.value
  raise "expected cache miss" unless response["geowebcache-cache-result"]=="MISS"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 256x256 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==256 and dim.height==256 and dim.type==:png)
end

wmts_gettile(node1, layer, gridset, "image/png", 2,2,1) do |response|
  response.value
  raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 256x256 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==256 and dim.height==256 and dim.type==:png)
end


puts "PASS"
