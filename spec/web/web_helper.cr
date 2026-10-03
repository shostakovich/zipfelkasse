require "../spec_helper"
require "../store/expense_fixture"

# Kemal keeps routes, filters and handlers globally; each app starts from
# scratch, like in Kemal's own specs.
def reset_kemal : Nil
  Kemal.config.clear
  Kemal::FilterHandler::INSTANCE.tree = Radix::Tree(Array(Kemal::FilterHandler::FilterBlock)).new
  Kemal::RouteHandler::INSTANCE.routes = Radix::Tree(Kemal::Route).new
  Kemal::RouteHandler::INSTANCE.cached_routes = Kemal::LRUCache(String, Radix::Result(Kemal::Route)).new(Kemal.config.max_route_cache_size)
end

# Runs the app's full handler chain in memory (no port).
class TestServer
  getter app : Zipfelkasse::App
  getter store : Zipfelkasse::Store
  getter log_io = SPEC_LOG
  @handler : HTTP::Handler

  def initialize(config = Zipfelkasse::Config.new, @store = Zipfelkasse::Store.open(":memory:"))
    config.location = Time::Location::UTC
    reset_kemal
    @app = Zipfelkasse::App.new(config, @store)
    @handler = HTTP::Server.build_middleware(@app.handlers)
  end

  def d : Zipfelkasse::Web::Deps
    @app.deps
  end

  def close : Nil
    @store.close
  end

  def request(method : String, path : String, body : String? = nil, headers = HTTP::Headers.new,
              cookies = {} of String => String) : HTTP::Client::Response
    headers = headers.dup
    headers["Host"] ||= "example.com"
    cookies.each { |k, v| headers.add("Cookie", "#{k}=#{v}") }
    call(HTTP::Request.new(method, path, headers, body))
  end

  def call(req : HTTP::Request) : HTTP::Client::Response
    io = IO::Memory.new
    res = HTTP::Server::Response.new(io)
    @handler.call(HTTP::Server::Context.new(req, res))
    res.close
    io.rewind
    HTTP::Client::Response.from_io(io, ignore_body: req.method == "HEAD")
  end

  def get(path : String, cookies = {} of String => String) : HTTP::Client::Response
    request("GET", path, cookies: cookies)
  end

  def post_form(path : String, form : Hash(String, String) | Hash(String, Array(String)) | URI::Params,
                cookies = {} of String => String) : HTTP::Client::Response
    body = form.is_a?(URI::Params) ? form.to_s : URI::Params.encode(form)
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    request("POST", path, body, headers, cookies)
  end
end

def with_server(config = Zipfelkasse::Config.new, &)
  srv = TestServer.new(config)
  begin
    yield srv
  ensure
    srv.close
  end
end

def who_cookie(id : Int64) : Hash(String, String)
  {Zipfelkasse::Web::IDENTITY_COOKIE => id.to_s}
end
