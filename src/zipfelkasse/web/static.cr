require "digest/sha256"

module Zipfelkasse::Web
  # The static files (CSS, JS, icons), embedded byte for byte.
  module Static
    # relative path (e.g. "icons/icon-192.png") → content
    FILES = {} of String => Bytes
    {% for path in system("cd #{__DIR__}/../../../internal/web/static && find . -type f | sort").lines %}
      FILES[{{ path[2..] }}] = {{ read_file("#{__DIR__}/../../../internal/web/static/#{path[2..].id}") }}.to_slice
    {% end %}

    # File name → short hash for cache busting (first 5 bytes of SHA-256).
    HASHES = FILES.to_h { |name, bytes| {name, Digest::SHA256.hexdigest(bytes)[0, 10]} }

    # "app.css" → "/static/app.css?v=…"
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

    # GET /static/<path>: with ?v=… cached for a year, otherwise 5 minutes.
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
