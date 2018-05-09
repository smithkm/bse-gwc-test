require 'net/http'
require 'rexml/document'
require 'rexml/xpath'
require 'rexml/element'
require 'dimensions'

$manual_truncate_on_gridset_change = true
$xstream_class_remove = true

$node1 = URI('http://localhost:8080/geoserver/')
$node2 = URI('http://localhost:8080/geoserver/')
nodes = [$node1, $node2]

layer = "na-roads:ne_10m_roads_north_america"

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

def auth_admin(request)
  request.basic_auth "admin", "geoserver"
end

def strip_class_attributes(doc)
  REXML::XPath.each(doc, '//@class') {|attr| attr.remove} if $xstream_class_remove
  return doc
end

# GETs URI and parses as XML, then yields the document to block.  Serializes result of block and POSTs back to URI.
def rest_update(uri, method: Net::HTTP::Put)
  request = Net::HTTP::Get.new uri
  request.add_field("Accept","application/xml")
  auth_admin(request)
  
  Net::HTTP.start(uri.host, uri.port) do |http|
    response = http.request request
    response.value

    doc = REXML::Document.new response.body
    
    doc = strip_class_attributes(yield doc)
    
    request2 = method.new uri
    request2.content_type = 'application/xml'
    auth_admin(request2)

    request2.body=doc.to_s
    
    response2 = http.request request2
    response.value

  end
    
end

# PUTs a REXML document to a rest endpoint
def rest_get(uri)
  
  request = Net::HTTP::Get.new uri
  request.add_field("Accept","application/xml")
  auth_admin(request)
  
  Net::HTTP.start(uri.host, uri.port) do |http|
    response = http.request request
    response.value

    doc = REXML::Document.new response.body
    
    return doc
    
  end
    
end

def rest_add(uri, doc, method: Net::HTTP::Put)
  request = method.new uri
  request.content_type = 'application/xml'
  auth_admin(request)

  request.body=doc.to_s

  Net::HTTP.start(uri.host, uri.port) do |http|
    response = http.request request
    response.value
    
    return doc
    
  end

end

def rest_delete(uri)
  request = Net::HTTP::Delete.new uri
  auth_admin(request)

  Net::HTTP.start(uri.host, uri.port) do |http|
    response = http.request request
    response.value
    
    return response.body
    
  end

end

def rest_mass_truncate(baseuri, layer)
  uri = baseuri+"gwc/rest/masstruncate"
  request = Net::HTTP::Post.new uri
  request.content_type = 'text/xml'
  auth_admin(request)
  request.body="<truncateLayer><layerName>#{layer}</layerName></truncateLayer>"
  Net::HTTP.start(uri.host, uri.port) do |http|
    response = http.request request
    puts response.body
    response.value
  end
  
end

def rest_seed(baseuri, layer, gridset, format, type, zoom: nil, parameters: nil)
  uri = baseuri+"gwc/rest/seed/#{layer}.xml"
  request = Net::HTTP::Post.new uri
  request.content_type = 'text/xml'
  auth_admin(request)
  body = "<seedRequest><name>#{layer}</name><gridSetId>#{gridset}</gridSetId><format>#{format}</format><type>#{type}</type>"
  body += "<zoomStart>#{zoom.first}</zoomStart><zoomStop>#{zoom.last}</zoomStop>" unless zoom.nil?
  unless parameters.nil?
    body+="<parameters>"
    parameters.each_pair do |key, value|
      body +="<entry><string>#{key}</string><string>#{value}</string></entry>"
    end
    body+="</parameters>"
  end
  body += "</seedRequest>"
  request.body = body
  Net::HTTP.start(uri.host, uri.port) do |http|
    response = http.request request
    response.value
  end
  
end

def wmts_getcap(baseuri)
  wmts_uri = baseuri+"gwc/service/wmts?REQUEST=GetCapabilities"
  request = Net::HTTP::Get.new wmts_uri
  response = nil
  Net::HTTP.start(wmts_uri.host, wmts_uri.port) do |http|
    response = http.request request
  end
  yield response
end

def wmts_gettile(baseuri, layer, gridset, format, x,y,z)
  wmts_uri = baseuri+"gwc/service/wmts?layer=#{layer}&style=&tilematrixset=#{gridset}&Service=WMTS&Request=GetTile&Version=1.0.0&Format=#{format}&TileMatrix=#{gridset}%3A#{z}&TileCol=#{x}&TileRow=#{y}"
  request = Net::HTTP::Get.new wmts_uri
  response = nil
  Net::HTTP.start(wmts_uri.host, wmts_uri.port) do |http|
    response = http.request request
  end
  yield response
end

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

rest_add($node1+("gwc/rest/gridsets/"+gridset), gridset_body)

# Check that the gridset was added

raise "gridset #{gridset} not added to local layer catalog" if rest_get($node1+("gwc/rest/gridsets")).root.elements["/gridSets/gridSet/name[text()='#{gridset}']"].nil?
raise "gridset #{gridset} not added to remote layer catalog" if rest_get($node2+("gwc/rest/gridsets")).root.elements["/gridSets/gridSet/name[text()='#{gridset}']"].nil?

raise "gridset #{gridset} not added to local layer catalog" if rest_get($node1+("gwc/rest/gridsets/"+gridset)).root.elements["/gridSet/name[text()='#{gridset}']"].nil?
raise "gridset #{gridset} not added to remote layer catalog" if rest_get($node2+("gwc/rest/gridsets/"+gridset)).root.elements["/gridSet/name[text()='#{gridset}']"].nil?

# Add gridset to layer

rest_update($node1+("gwc/rest/layers/"+layer)) do |doc|
  doc.root.elements["//gridSubsets"].add_element(REXML::Element.new("gridSubset")).add_element("gridSetName").text=gridset
  doc
end

# Check that gridset was added to layer via REST

raise "gridset #{gridset} not added to local layer #{layer}" if rest_get($node1+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/gridSubsets/gridSubset/gridSetName[text()='#{gridset}']"].nil?
raise "gridset #{gridset} not added to remote layer #{layer}" if rest_get($node2+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/gridSubsets/gridSubset/gridSetName[text()='#{gridset}']"].nil?

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

wmts_gettile($node1, layer, gridset, "image/png", 2,1,0) do |response|
  response.value
  raise "expected cache miss" unless response["geowebcache-cache-result"]=="MISS"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 200x200 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==200 and dim.height==200 and dim.type==:png)
end

wmts_gettile($node2, layer, gridset, "image/png", 2,1,0) do |response|
  response.value
  raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 200x200 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==200 and dim.height==200 and dim.type==:png)
end

# Get a different tile
wmts_gettile($node2, layer, gridset, "image/png", 2,2,1) do |response|
  response.value
  raise "expected cache miss" unless response["geowebcache-cache-result"]=="MISS"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 200x200 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==200 and dim.height==200 and dim.type==:png)
end

wmts_gettile($node1, layer, gridset, "image/png", 2,2,1) do |response|
  response.value
  raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 200x200 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==200 and dim.height==200 and dim.type==:png)
end

rest_update($node1+("gwc/rest/gridsets/"+gridset)) do |doc|
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
  rest_mass_truncate($node1, layer)
end

# Get tiles again.  Dimensions should reflect new size and misses should indicate the cache was truncated
wmts_gettile($node1, layer, gridset, "image/png", 2,1,0) do |response|
  response.value
  raise "expected cache miss" unless response["geowebcache-cache-result"]=="MISS"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 256x256 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==256 and dim.height==256 and dim.type==:png)
end

wmts_gettile($node2, layer, gridset, "image/png", 2,1,0) do |response|
  response.value
  raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 256x256 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==256 and dim.height==256 and dim.type==:png)
end

# Get a different tile starting with second node
wmts_gettile($node2, layer, gridset, "image/png", 2,2,1) do |response|
  response.value
  raise "expected cache miss" unless response["geowebcache-cache-result"]=="MISS"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 256x256 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==256 and dim.height==256 and dim.type==:png)
end

wmts_gettile($node1, layer, gridset, "image/png", 2,2,1) do |response|
  response.value
  raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  dim =  Dimensions::Reader.new
  dim << response.body
  raise "expected 256x256 png but was #{dim.width}x#{dim.height} #{dim.type}" unless (dim.width==256 and dim.height==256 and dim.type==:png)
end


puts "PASS"
