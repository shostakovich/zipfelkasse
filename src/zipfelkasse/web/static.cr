require "digest/sha256"

module Zipfelkasse::Web
  module Static
    FILES = {} of String => Bytes
    {% for path in system("cd #{__DIR__}/../../static && find . -type f -not -name '.*' -not -name '_*' | sort").lines %}
      FILES[{{ path[2..] }}] = {{ read_file("#{__DIR__}/../../static/#{path[2..].id}") }}.to_slice
    {% end %}

    HASHES = FILES.to_h { |name, bytes| {name, Digest::SHA256.hexdigest(bytes)[0, 10]} }

    CONTENT_TYPES = {
      ".css"  => "text/css; charset=utf-8",
      ".js"   => "text/javascript; charset=utf-8",
      ".svg"  => "image/svg+xml",
      ".png"  => "image/png",
      ".webp" => "image/webp",
    }

    def self.url(name : String) : String
      "/static/#{name}?v=#{HASHES[name]}"
    end

    def self.send(env : HTTP::Server::Context, name : String, cache_control : String) : String
      bytes = FILES[name]? || raise Kemal::Exceptions::RouteNotFound.new(env)
      etag = %("#{HASHES[name]}")
      response = env.response
      response.headers["ETag"] = etag
      response.headers["Cache-Control"] = cache_control
      if env.request.headers["If-None-Match"]?.try(&.split(',').any? { |tag| tag.strip.lchop("W/") == etag })
        response.status_code = 304
      else
        response.content_type = CONTENT_TYPES[File.extname(name)]? || "application/octet-stream"
        response.content_length = bytes.size
        response.write(bytes)
      end
      ""
    end
  end
end
