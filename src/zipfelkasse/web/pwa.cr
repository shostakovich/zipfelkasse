module Zipfelkasse::Web
  # The icons in static/icons/ are exports of the Zipfelkasse logo (mouse
  # with abacus); static/mascot.webp is the header logo.

  # The primary color (Spliit green, --primary in light mode).
  THEME_COLOR = "#047756"

  class Handlers
    # The web app manifest (public, so that installing works even before a
    # person is selected). The name is the group name.
    def manifest(r : Request) : Nil
      name = @d.store.group_name
      r.response.headers["Content-Type"] = "application/manifest+json; charset=utf-8"
      r.response.headers["Cache-Control"] = "no-cache"
      JSON.build(r.response) do |j|
        j.object do
          j.field "background_color", "#ffffff"
          j.field "description", "Gemeinsame Ausgaben teilen"
          j.field "dir", "ltr"
          j.field "display", "standalone"
          j.field "icons" do
            j.array do
              {
                {"icons/icon-192.png", "192x192", "any"},
                {"icons/icon-512.png", "512x512", "any"},
                {"icons/maskable-512.png", "512x512", "maskable"},
              }.each do |file, sizes, purpose|
                j.object do
                  j.field "src", Static.url(file)
                  j.field "sizes", sizes
                  j.field "type", "image/png"
                  j.field "purpose", purpose
                end
              end
            end
          end
          j.field "id", "/"
          j.field "lang", "de"
          j.field "name", name
          j.field "scope", "/"
          j.field "short_name", name
          j.field "shortcuts" do
            j.array do
              j.object { j.field "name", "Ausgabe hinzufügen"; j.field "url", "/ausgaben/neu" }
              j.object { j.field "name", "Salden"; j.field "url", "/salden" }
            end
          end
          j.field "start_url", "/"
          j.field "theme_color", THEME_COLOR
        end
      end
    end

    # /sw.js from static/ (scope "/" needs the file at the root). No
    # caching, so that changes take effect immediately.
    def service_worker(r : Request) : Nil
      r.response.headers["Content-Type"] = "text/javascript; charset=utf-8"
      r.response.headers["Cache-Control"] = "no-cache"
      r.response.write(Static::FILES["sw.js"])
    end

    def favicon(r : Request) : Nil
      r.response.headers["Content-Type"] = "image/png"
      r.response.headers["Cache-Control"] = "public, max-age=86400"
      r.response.write(Static::FILES["icons/favicon-32.png"])
    end
  end
end
