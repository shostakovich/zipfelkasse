# Runs the app's full handler chain in memory (no port). Kemal keeps routes,
# filters and handlers globally; each app starts from scratch, like in
# Kemal's own specs.
class TestServer
  getter app : App
  getter store : Store
  @handler : HTTP::Handler

  def initialize(config = Config.new, @store = Store.open(":memory:"))
    config.location = Time::Location::UTC
    reset_kemal
    @app = App.new(config, @store)
    @handler = HTTP::Server.build_middleware(@app.handlers)
  end

  def close : Nil
    @store.close
  end

  def get(path : String, cookies = {} of String => String) : HTTP::Client::Response
    request("GET", path, cookies: cookies)
  end

  def post_form(path : String, form : Hash(String, String), cookies = {} of String => String) : HTTP::Client::Response
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    request("POST", path, URI::Params.encode(form), headers, cookies)
  end

  def request(method : String, path : String, body : String? = nil, headers = HTTP::Headers.new,
              cookies = {} of String => String) : HTTP::Client::Response
    headers = headers.dup
    headers["Host"] ||= "example.com"
    cookies.each { |name, value| headers.add("Cookie", "#{name}=#{value}") }
    io = IO::Memory.new
    response = HTTP::Server::Response.new(io)
    @handler.call(HTTP::Server::Context.new(HTTP::Request.new(method, path, headers, body), response))
    response.close
    io.rewind
    HTTP::Client::Response.from_io(io, ignore_body: method == "HEAD")
  end

  private def reset_kemal : Nil
    Kemal.config.clear
    Kemal::FilterHandler::INSTANCE.tree = Radix::Tree(Array(Kemal::FilterHandler::FilterBlock)).new
    Kemal::RouteHandler::INSTANCE.routes = Radix::Tree(Kemal::Route).new
    Kemal::RouteHandler::INSTANCE.cached_routes = Kemal::LRUCache(String, Radix::Result(Kemal::Route)).new(Kemal.config.max_route_cache_size)
  end
end

def with_server(config = Config.new, &)
  server = TestServer.new(config)
  begin
    yield server
  ensure
    server.close
  end
end
