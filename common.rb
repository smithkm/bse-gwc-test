require 'net/http'
require 'rexml/document'
require 'rexml/xpath'
require 'rexml/element'

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
