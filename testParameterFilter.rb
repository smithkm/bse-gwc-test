# coding: utf-8
require 'net/http'
require 'rexml/document'
require 'rexml/xpath'
require 'rexml/element'
require 'dimensions'

require './common.rb'

gridset="EPSG:4326"

def add_parameter_filter(doc, filter)
  filters = doc.root.elements["/GeoServerLayer/parameterFilters"]
  if filters.nil?
    filters = REXML::Element.new("parameterFilters")
    doc.root.elements["/GeoServerLayer"].add_element(filters)
  end
  filters.add_element filter
  filter
end

def update_parameter_filter(doc, key)
  filters = doc.root.elements["/GeoServerLayer/parameterFilters"]
  if filters.nil?
    filters = REXML::Element.new("parameterFilters")
    doc.root.elements["/GeoServerLayer"].add_element(filters)
  end
  filter = filters.elements["*[key/text()='#{key}']"]
  filters.delete filter
  filter = yield filter
  filters.add_element filter unless filter.nil?
  return filter
end

def string_parameter_filter(key, default, values, case: nil, locale: nil)
  filter = REXML::Element.new("stringParameterFilter")
  filter.add_element("key").text=key
  filter.add_element("defaultValue").text=default
  kase = binding.local_variable_get(:case) # being tricksey to allow a named parameter that's a normally reserved word.
  raise "case and locale should both be nil or both be not nil" unless kase.nil? == locale.nil?
  unless kase.nil?
    normalize = filter.add_element("normalize")
    normalize.add_element("case").text=kase.upcase
    normalize.add_element("locale").text=locale
  end
  values_node = filter.add_element("values")
  values.each {|value| values_node.add_element("string").text= value}
  return filter
end

# make a GetTile request to node1, it should be a miss, then try rach of the other nodes, they chould be hits.  If a block is given it will be passed all response objects for validation
def get_tile_miss_hit(node1, nodes, layer, gridset, format, x,y,z, params:{})
  wmts_gettile(node1, layer, gridset, format, x,y,z, params: params) do |request,response|
    check_ok(request, response)
    raise "expected cache miss" unless response["geowebcache-cache-result"]=="MISS"
    yield response if block_given?
  end
  nodes.each do |base|
    wmts_gettile(base, layer, gridset, "image/png", x,y,z) do |request,response|
      check_ok(request, response)
      raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
      yield response if block_given?
    end
  end
end

config = Config.read do |config|
  config["xstream_class_remove"]=false
  config["nodes"]=["http://localhost:8080/geoserver/"]
  config["layer"]="a layer with global extent"
  config["manual_truncate_on_parameter_filter_change"]=false
end

$xstream_class_remove = config["xstream_class_remove"]
$manual_truncate_on_gridset_change = config["manual_truncate_on_parameter_filter_change"]

nodes = config["nodes"].map {|uri| URI(uri)}
node1 = nodes[0]
node2 = nodes[-1]

layer = config["layer"]

# Make sure we are ready for the test

nodes.each do |base|
  begin
    rest_mass_truncate(base, layer)
  rescue Net::HTTPFatalError,Net::HTTPServerException
    puts "Pre-test Truncate failed, probably due to gridset not existing, this is probably fine"
  end
  rest_update(base+("gwc/rest/layers/"+layer)) do |doc|
    e = doc.root.elements["//parameterFilters/*[text()!='STYLE']"]
    e.parent.delete e unless e.nil?
    doc
  end
end

# Add filter to layer

rest_update(node1+("gwc/rest/layers/"+layer)) do |doc|
  filter = add_parameter_filter(doc, string_parameter_filter("FOO", "defaultFoo", ["a", "b", "c", "A"]))
  doc
end

# Check that filter was added to layer via REST

nodes.each do |base|
  raise "stringParameterFilter 'FOO' not added to layer #{layer} on node #{base}" if rest_get(node1+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/parameterFilters/stringParameterFilter/key[text()='FOO']"].nil?
end


# Check that we get correct behaviour for  WMTS GetTile

get_tile_miss_hit(node1, nodes, layer, gridset, "image/png", 2,1,2)

# Try a different tile starting with a different node

get_tile_miss_hit(node2, nodes, layer, gridset, "image/png", 2,2,3)

# A different parameter value should be cached separately
get_tile_miss_hit(node1, nodes, layer, gridset, "image/png", 2,1,2, params:{"foo"=>"a"})
get_tile_miss_hit(node2, nodes, layer, gridset, "image/png", 2,2,3, params:{"foo"=>"a"})

# A request with a parameter value not in the filter should be rejected
nodes.each do |base|
  wmts_gettile(base, layer, gridset, "image/png", 2,1,2, params:{"foo"=>"X"}) do |request,response|
    
    raise "expected a 500" unless response.code.to_i==500 # This should really be a 4xx error
  end
end

# By default the filter should be case sensitive
get_tile_miss_hit(node1, nodes, layer, gridset, "image/png", 2,1,2, params:{"foo"=>"A"})

rest_update(node1+("gwc/rest/layers/"+layer)) do |doc|
  update_parameter_filter(doc, 'FOO') do |old|
    string_parameter_filter("FOO", "defaultFoo", ["a", "b", "c"], case:"UPPER", locale:"en")
  end
  doc
end

nodes.each do |base|
  raise "stringParameterFilter 'FOO' not added to layer #{layer} on node #{base}" if rest_get(node1+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/parameterFilters/stringParameterFilter/key[text()='FOO']"].nil?
  raise "stringParameterFilter 'FOO' not normalizing to upper case on node #{base}" if rest_get(node1+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/parameterFilters/stringParameterFilter[key/text()='FOO']/normalize/case[text()='UPPER']"].nil?
  raise "stringParameterFilter 'FOO' not using locale 'en' on node #{base}" if rest_get(node1+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/parameterFilters/stringParameterFilter[key/text()='FOO']/normalize/locale[text()='en']"].nil?
end

rest_mass_truncate(node1, layer) if $manual_truncate_on_gridset_change

# This change should truncate everything
get_tile_miss_hit(node1, nodes, layer, gridset, "image/png", 2,1,2)
get_tile_miss_hit(node2, nodes, layer, gridset, "image/png", 2,2,3)
get_tile_miss_hit(node1, nodes, layer, gridset, "image/png", 2,1,2, params:{"foo"=>"a"})
get_tile_miss_hit(node2, nodes, layer, gridset, "image/png", 2,2,3, params:{"foo"=>"a"})

# We should now get a hit the first time we use a capital letter
nodes.each do |base|
  wmts_gettile(base, layer, gridset, "image/png", 2,1,2, params:{"foo"=>"A"}) do |request,response|
    raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  end
end

# Lets try Turkish
rest_update(node1+("gwc/rest/layers/"+layer)) do |doc|
  update_parameter_filter(doc, 'FOO') do |old|
    string_parameter_filter("FOO", "defaultFoo", ["i", "ı", "c"], case:"LOWER", locale:"tr")
  end
  doc
end
rest_mass_truncate(node1, layer) if $manual_truncate_on_gridset_change

nodes.each do |base|
  raise "stringParameterFilter 'FOO' not added to layer #{layer} on node #{base}" if rest_get(node1+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/parameterFilters/stringParameterFilter/key[text()='FOO']"].nil?
  raise "stringParameterFilter 'FOO' not normalizing to lower case on node #{base}" if rest_get(node1+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/parameterFilters/stringParameterFilter[key/text()='FOO']/normalize/case[text()='LOWER']"].nil?
  raise "stringParameterFilter 'FOO' not using locale 'tr' on node #{base}" if rest_get(node1+("gwc/rest/layers/"+layer)).root.elements["/GeoServerLayer/parameterFilters/stringParameterFilter[key/text()='FOO']/normalize/locale[text()='tr']"].nil?
end


# This change should truncate everything
get_tile_miss_hit(node1, nodes, layer, gridset, "image/png", 2,1,2)
get_tile_miss_hit(node2, nodes, layer, gridset, "image/png", 2,2,3)
get_tile_miss_hit(node1, nodes, layer, gridset, "image/png", 2,1,2, params:{"foo"=>"i"})
get_tile_miss_hit(node2, nodes, layer, gridset, "image/png", 2,2,3, params:{"foo"=>"i"})

# We should now get a hit the first time we use a capital dotted I
nodes.each do |base|
  wmts_gettile(base, layer, gridset, "image/png", 2,1,2, params:{"foo"=>"İ"}) do |request,response|
    raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  end
end

# Dotless I should be a miss

get_tile_miss_hit(node1, nodes, layer, gridset, "image/png", 2,1,2, params:{"foo"=>"I"})
get_tile_miss_hit(node2, nodes, layer, gridset, "image/png", 2,2,3, params:{"foo"=>"I"})

# We should now get a hit the first time we use a lower case dotless I
nodes.each do |base|
  wmts_gettile(base, layer, gridset, "image/png", 2,1,2, params:{"foo"=>"ı"}) do |request,response|
    raise "expected cache hit" unless response["geowebcache-cache-result"]=="HIT"
  end
end

rest_update(node1+("gwc/rest/layers/"+layer)) do |doc|
  update_parameter_filter(doc, 'FOO') do |old|
    string_parameter_filter("FOO", "defaultFoo", ["a", "b", "c"], case:"UPPER", locale:"en")
  end
  doc
end
rest_mass_truncate(node1, layer) if $manual_truncate_on_gridset_change


puts "PASS"
