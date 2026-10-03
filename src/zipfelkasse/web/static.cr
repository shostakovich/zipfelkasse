require "digest/sha256"

module Zipfelkasse::Web
  module Static
    FILES = {} of String => Bytes
    {% for path in system("cd #{__DIR__}/../../../internal/web/static && find . -type f -not -name '.*' -not -name '_*' | sort").lines %}
      FILES[{{ path[2..] }}] = {{ read_file("#{__DIR__}/../../../internal/web/static/#{path[2..].id}") }}.to_slice
    {% end %}

    HASHES = FILES.to_h { |name, bytes| {name, Digest::SHA256.hexdigest(bytes)[0, 10]} }

    def self.url(name : String) : String
      if h = HASHES[name]?
        "/static/#{name}?v=#{h}"
      else
        "/static/#{name}"
      end
    end

    CONTENT_TYPES = {
      ".css"  => "text/css; charset=utf-8",
      ".js"   => "text/javascript; charset=utf-8",
      ".svg"  => "image/svg+xml",
      ".png"  => "image/png",
      ".webp" => "image/webp",
    }

    def self.content_type(name : String) : String
      CONTENT_TYPES[File.extname(name)]? || "application/octet-stream"
    end

    def self.serve(req : Request) : Nil
      name = req.path.lchop("/static/")
      bytes = FILES[name]? || return Web.text_error(req.ctx, 404, "404 page not found")
      res = req.response
      res.headers["Cache-Control"] = req.query("v").empty? ? "public, max-age=300" : "public, max-age=31536000, immutable"
      res.content_type = content_type(name)
      res.headers["Accept-Ranges"] = "bytes"
      res.content_length = bytes.size
      res.write(bytes)
    end
  end
end
