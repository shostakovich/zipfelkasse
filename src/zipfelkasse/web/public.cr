module Zipfelkasse::Web
  # The primary color (Spliit green, --primary in light mode).
  THEME_COLOR = "#047756"

  class PublicController < Controller
    def register : Nil
      get("/static/*path") do |env|
        name = env.params.url["path"]
        Static.send(env, name, env.query("v").empty? ? "public, max-age=300" : "public, max-age=31536000, immutable")
      end
      get("/sw.js") { |env| Static.send(env, "sw.js", "no-cache") }
      get("/favicon.ico") { |env| Static.send(env, "icons/favicon-32.png", "public, max-age=86400") }
      get("/manifest.webmanifest") { |env| manifest(env) }
      get("/healthz") { |env| healthz(env) }
    end

    private def healthz(env : HTTP::Server::Context) : String
      @d.store.ping
      env.response.content_type = "text/plain; charset=utf-8"
      "ok\n"
    rescue ex
      Log.error(exception: ex) { "health check failed" }
      env.response.status_code = 503
      env.response.content_type = "text/plain; charset=utf-8"
      "db unavailable\n"
    end

    private def manifest(env : HTTP::Server::Context) : String
      name = @d.store.group_name
      env.response.content_type = "application/manifest+json; charset=utf-8"
      env.response.headers["Cache-Control"] = "no-cache"
      {
        name:             name,
        short_name:       name,
        description:      "Gemeinsame Ausgaben teilen",
        lang:             "de",
        dir:              "ltr",
        id:               "/",
        start_url:        "/",
        scope:            "/",
        display:          "standalone",
        background_color: "#ffffff",
        theme_color:      THEME_COLOR,
        icons:            {
          {file: "icons/icon-192.png", sizes: "192x192", purpose: "any"},
          {file: "icons/icon-512.png", sizes: "512x512", purpose: "any"},
          {file: "icons/maskable-512.png", sizes: "512x512", purpose: "maskable"},
        }.map { |icon| {src: Static.url(icon[:file]), sizes: icon[:sizes], type: "image/png", purpose: icon[:purpose]} },
        shortcuts: [
          {name: "Ausgabe hinzufügen", url: "/ausgaben/neu"},
          {name: "Salden", url: "/salden"},
        ],
      }.to_json
    end
  end
end
