require 'rubygems'
require 'neography'
require 'sinatra/base'
require 'uri'

class Neovigator < Sinatra::Application
  set :haml, :format => :html5 
  set :app_file, __FILE__

  def initialize
    @page_size = 50
    super()
  end

  configure :test do
    require 'net-http-spy'
    Net::HTTP.http_logger_options = {:verbose => true} 
    @page_size = 50
  end

  helpers do
    def link_to(url, text=url, opts={})
      attributes = ""
      opts.each { |key,value| attributes << key.to_s << "=\"" << value << "\" "}
      "<a href=\"#{url}\" #{attributes}>#{text}</a>"
    end

    def neo
      @neo = Neography::Rest.new(ENV['NEO4J_URL'] || "http://localhost:7474")
    end
  end

  def create_graph
    graph_exists = neo.get_node_properties(1)
    return if graph_exists && graph_exists['name']
  end


  def neighbours
    {"order"         => "depth first",
     "uniqueness"    => "none",
     "return filter" => {"language" => "builtin", "name" => "all_but_start_node"},
     "depth"         => 1}
  end

  def node_id(node)
    case node
      when Hash
        node["self"].split('/').last
      when String
        node.split('/').last
      else
        node
    end
  end

  def get_adjacent_for_donut(id, skip, limit)
    out_ = neo.execute_query("start n=node("+id+") match n-[r]->m return ID(m), m.name?,type(r) skip "+skip.to_s()+" limit "+limit.to_s())
    in_ = neo.execute_query("start n=node("+id+") match n<-[r]-m return ID(m), m.name?,type(r) skip "+skip.to_s()+" limit "+limit.to_s())
    return out_, in_
  end

  def get_properties(node)
    properties = "<ul>"
    node["data"].each_pair do |key, value|
        properties << "<li><b>#{key}:</b> #{value}</li>"
      end
    properties + "</ul>"
  end

  get '/resources/moreAdjacent' do
    content_type :json
    
    page_number = Integer(params[:page])
    type = params[:type]
    id = params[:id]
    skip = @page_size * (page_number - 1)
    limit = @page_size
    out_, in_ = get_adjacent_for_donut(id, skip, limit)

    rels = Hash.new{|h, k| h[k] = []}
    attributes = Array.new
    nodes = Hash.new

    if type == "Outgoing"
      all_nodes = out_['data']
    else
      all_nodes = in_['data']
    end

    all_nodes.each do |result|
      data ={ 
          "name"=>result[1],
          :id => result[0].to_s()
       } 
      nodes["http://localhost:7474/db/data/node/"+result[0].to_s()] = data
      rels["#{type}:#{result[2]}"] << {:values => data }
    end

      rels.each_pair do |key, value|
        attributes << {:id => key.split(':').last, :name => key, :values => value.collect{|v| v[:values]} }
      end

    @node = {
              :data => {:attributes => attributes}
            }

    @node.to_json
  end

  get '/resources/show' do
    content_type :json
    node = neo.get_node(params[:id]) 
    
    count_out = neo.execute_query("start n=node("+params[:id]+") match n-[r]->m return count(m)")['data'][0][0]
    count_in = neo.execute_query("start n=node("+params[:id]+") match n<-[r]-m return count(m)")['data'][0][0]
    
    out_, in_ = get_adjacent_for_donut(params[:id],0,@page_size)

    incoming = Hash.new{|h, k| h[k] = []}
    outgoing = Hash.new{|h, k| h[k] = []}
    nodes = Hash.new
    attributes = Array.new
    all_nodes = out_['data'] + in_['data']

    all_nodes.each do |result|
      data ={ 
          "name"=>result[1]
       } 
      nodes["http://localhost:7474/db/data/node/"+result[0].to_s()] = data
    end

    out_['data'].each do |result|
      outgoing["Outgoing:#{result[2]}"] << {:values => nodes["http://localhost:7474/db/data/node/"+result[0].to_s()].merge({:id => result[0].to_s() }) }
    end

    in_['data'].each do |result|
      incoming["Incoming:#{result[2]}"] << {:values => nodes["http://localhost:7474/db/data/node/"+result[0].to_s()].merge({:id => result[0].to_s() }) }
    end

    if (count_out > 1)
      outgoing["Outgoing:more_subjects"] << {:values=>{:id =>"more_outgoing:1", :name => 'get more outgoing relationships', :values => "" }}
    end

    if (count_in > 1)
      incoming["Incoming:more_subjects"] << {:values=>{:id =>"more_incoming:1", :name => 'get more ingoing relationships',:values => "" }}
    end

      incoming.merge(outgoing).each_pair do |key, value|
        attributes << {:id => key.split(':').last, :name => key, :values => value.collect{|v| v[:values]} }
      end


   attributes = [{"name" => "No Relationships","name" => "No Relationships","values" => [{"id" => "#{params[:id]}","name" => "No Relationships "}]}] if attributes.empty?

    @node = {:details_html => "<h2>Neo ID: #{node_id(node)}</h2>\n<p class='summary'>\n#{get_properties(node)}</p>\n",
              :data => {:attributes => attributes, 
                        :name => node["data"]["name"],
                        :id => node_id(node)}
            }

    @node.to_json

  end

  get '/' do
    create_graph
    @neoid = params["neoid"]
    haml :index
  end

  def extract_node_id(node)
    case node
      when Hash
        node["self"].split('/').last
      else
        nil
    end
  end

  def resultSetHtml(resultSet)
    html_output = ""
    resultSet.each do |row|
      processed_row = Array.new
      # iterate through the columsn
      row.each do |column|
        node_id = extract_node_id(column)
        if node_id
          processed_row.push(['node_id',node_id])
          html_output = html_output + " <a class=\"nodelink\" href=\"#\" ref=\"" +node_id+"\">"+node_id+"</a>"
        else
           processed_row.push(['field',column])
          html_output = html_output + " " +column
        end
      end
      html_output = html_output + "<br> "
    end
    html_output
  end

  get '/query' do
    haml "results"
  end

  get '/cypher' do
    cypher_query = params[:query]
    json_answer = neo.execute_query(cypher_query,{}).to_json
    json_answer = JSON.parse(json_answer)
    processed_resultset =  Array.new

    result_output =""

    # getting the result set
    columns = json_answer["columns"]
    data = json_answer["data"]

    html_response = resultSetHtml(data)
    if html_response==""
      result_output = "No results were found for the given cypher query"
    end
    result_output = html_response
  end

end