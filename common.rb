require 'net/http'
require 'rexml/document'
require 'rexml/xpath'
require 'rexml/element'
require 'yaml'
require 'fileutils'
require 'json'

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

    yield configurator = Config.new(config, needed_config_values)

    configurator["admin"]={"type"=>"basic", "username"=>"admin", "password"=>"geoserver"}
    configurator["user"]={"type"=>"anonymous"}
    
    unless needed_config_values.empty?
      $stderr.puts "#{config_file} missing config values: #{needed_config_values}"
      File.write(config_file, config.to_yaml)
      raise "Please check/fill in values before re-running"
    end

    $admin_auth = authorizer(config["admin"])
    $user_auth = authorizer(config["user"])
    
    return config
  end
end

def authorizer(config_map)
  case config_map["type"]
  when "anonymous"
    return lambda {|request| request}
  when "basic"
    return lambda {|request| request.basic_auth config_map["username"], config_map["password"]}
  when "bearer"
    return lambda {|request| request.add_field("Authorization","Bearer #{config_map["token"]}")}
  when "mbse-auth0"
    return lambda do |request|
      uri = URI(config_map["uri"])
      auth_request = Net::HTTP::Post.new uri 
      auth_request.content_type = "application/json"
      auth_request.body=JSON.generate(config_map.reject{|key, value| ["type", "uri"].include? key})
      Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
        response = http.request auth_request
        check_ok(auth_request, response)
        token = JSON.parse(response.body)["access_token"]
        request.add_field("Authorization","Bearer #{token}")
      end
    end
  end
end


def auth_admin(request)
  $admin_auth[request]
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
  
  Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    response = http.request request
    check_ok(request, response)

    doc = REXML::Document.new response.body
    
    doc = strip_class_attributes(yield doc)
    
    request2 = method.new uri
    request2.content_type = 'application/xml'
    auth_admin(request2)

    request2.body=doc.to_s
    
    response2 = http.request request2
    check_ok(request2, response2)

  end
    
end

# PUTs a REXML document to a rest endpoint
def rest_get(uri)
  
  request = Net::HTTP::Get.new uri
  request.add_field("Accept","application/xml")
  auth_admin(request)
  
  Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    response = http.request request
    check_ok(request, response)

    doc = REXML::Document.new response.body
    
    return doc
    
  end
    
end

def rest_add(uri, doc, method: Net::HTTP::Put)
  request = method.new uri
  request.content_type = 'application/xml'
  auth_admin(request)

  request.body=doc.to_s

  Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    response = http.request request
    check_ok(request, response)
    
    return doc
    
  end

end

def rest_delete(uri)
  request = Net::HTTP::Delete.new uri
  auth_admin(request)

  Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    response = http.request request
    check_ok(request, response)
    
    return response.body
    
  end

end

def rest_mass_truncate(baseuri, layer)
  uri = baseuri+"gwc/rest/masstruncate"
  request = Net::HTTP::Post.new uri
  request.content_type = 'text/xml'
  auth_admin(request)
  request.body="<truncateLayer><layerName>#{layer}</layerName></truncateLayer>"
  Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    response = http.request request
    check_ok(request, response)
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
  Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    response = http.request request
    check_ok(request, response)
  end
  
end

def wmts_getcap(baseuri)
  wmts_uri = baseuri+"gwc/service/wmts?REQUEST=GetCapabilities"
  request = Net::HTTP::Get.new wmts_uri
  $user_auth[request]
  response = nil
  Net::HTTP.start(wmts_uri.host, wmts_uri.port, :use_ssl => uri.scheme == 'https') do |http|
    response = http.request request
  end
  yield request, response
end

def wmts_gettile(baseuri, layer, gridset, format, x,y,z, params:{})
  base_params = {"LAYER"=>layer, "TILEMATRIXSET"=>gridset, "TILEMATRIX"=>"#{gridset}:#{z}", "SERVICE"=>"WMTS", "VERSION"=>"1.0.0", "FORMAT"=>format, "TILECOL"=>x, "TILEROW"=>y, "REQUEST"=>"GetTile"}

  all_params=params.merge base_params
  all_params["STYLE"]||=""
  #p all_params
  wmts_uri = baseuri+("gwc/service/wmts?"+all_params.each_pair.map {|key, value| "#{URI.escape key.to_s}=#{URI.escape value.to_s}"}.join("&"))
  request = Net::HTTP::Get.new wmts_uri
  $user_auth[request]
  response = nil
  Net::HTTP.start(wmts_uri.host, wmts_uri.port, :use_ssl => wmts_uri.scheme == 'https') do |http|
    response = http.request request
  end
  yield request, response
end

def check_status(request, response, status)
  if(response.code.to_i!=status)
    puts "* Expected status #{status} but was #{response.code}"
    puts "* Request: #{request.uri}"
    request.each_header {|key, value| puts "* - #{key}: #{value}"}
    puts "* - Body: \n#{request.body}" unless request.body.nil? or request.body.empty?
    puts "* Response #{response.code} #{response.message}"
    response.each_header {|key, value| puts "* - #{key}: #{value}"}
    puts "* - Body: \n#{response.body}" unless response.body.nil? or response.body.empty?
    exit 1
  end
end

def check_ok(request, response)
  check_status(request, response, 200)
end
