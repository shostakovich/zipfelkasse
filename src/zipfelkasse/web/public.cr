module Zipfelkasse::Web
  # The light page colour of each look (installed app's splash screen and title bar).
  PAGE_COLORS = {Look::Felt => "#ece4d4", Look::Clean => "#f6f7f9"}

  class PublicController < Controller
    def register : Nil
      get("/static/*path") do |env|
        name = env.params.url["path"]
        Static.send(env, name, env.query("v").empty? ? "public, max-age=300" : "public, max-age=31536000, immutable")
      end
      get("/sw.js") { |env| Static.send(env, "sw.js", "no-cache") }
      get("/favicon.ico") { |env| Static.send(env, "icons/favicon-clean-light.png", "public, max-age=86400") }
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
      look = env.look
      name_of_look = look.to_s.downcase
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
        background_color: PAGE_COLORS[look],
        theme_color:      PAGE_COLORS[look],
        icons:            {
          {file: "icons/icon-#{name_of_look}-192.webp", sizes: "192x192", purpose: "any"},
          {file: "icons/icon-#{name_of_look}-512.webp", sizes: "512x512", purpose: "any"},
          {file: "icons/maskable-#{name_of_look}-512.webp", sizes: "512x512", purpose: "maskable"},
        }.map { |icon| {src: Static.url(icon[:file]), sizes: icon[:sizes], type: "image/webp", purpose: icon[:purpose]} },
        shortcuts: [
          {name: "Ausgabe hinzufügen", url: "/ausgaben/neu"},
          {name: "Salden", url: "/salden"},
        ],
      }.to_json
    end
  end
end
