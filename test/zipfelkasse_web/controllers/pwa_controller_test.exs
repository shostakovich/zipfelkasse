defmodule ZipfelkasseWeb.PwaControllerTest do
  use ZipfelkasseWeb.ConnCase

  alias Zipfelkasse.Settings

  test "the manifest is named after the group", %{conn: conn} do
    {:ok, _setting} = Settings.update_settings(nil, %{group_name: "WG Süd"})

    conn = get(conn, ~p"/manifest.webmanifest")

    assert response_content_type(conn, :json) =~ "application/manifest+json"
    assert get_resp_header(conn, "cache-control") == ["no-cache"]

    assert %{
             "name" => "WG Süd",
             "short_name" => "WG Süd",
             "description" => "Gemeinsame Ausgaben teilen",
             "lang" => "de",
             "id" => "/",
             "start_url" => "/",
             "scope" => "/",
             "display" => "standalone",
             "background_color" => "#ffffff",
             "theme_color" => "#ffffff",
             "icons" => icons,
             "shortcuts" => shortcuts
           } = JSON.decode!(response(conn, 200))

    assert Enum.map(icons, &{&1["src"], &1["sizes"], &1["type"], &1["purpose"]}) == [
             {"/images/icons/icon-192.webp", "192x192", "image/webp", "any"},
             {"/images/icons/icon-512.webp", "512x512", "image/webp", "any"},
             {"/images/icons/maskable-512.webp", "512x512", "image/webp", "maskable"}
           ]

    assert shortcuts == [
             %{"name" => "Ausgabe hinzufügen", "url" => "/expenses/new"},
             %{"name" => "Salden", "url" => "/balances"}
           ]
  end

  test "the service worker is never cached and answers offline navigations", %{conn: conn} do
    conn = get(conn, ~p"/sw.js")

    assert response_content_type(conn, :javascript)
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    body = response(conn, 200)
    assert body =~ "Keine Verbindung"
    assert body =~ "status: 503"
    refute body =~ "caches."
  end

  test "the favicon at the root is the light one", %{conn: conn} do
    conn = get(conn, "/favicon.ico")

    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert response(conn, 200) == File.read!("priv/static/images/icons/favicon-light.png")
  end

  test "pages link the manifest and name the installed app after the group", %{conn: conn} do
    html = conn |> get(~p"/who") |> html_response(200)
    document = LazyHTML.from_document(html)

    assert LazyHTML.attribute(LazyHTML.query(document, "link[rel=manifest]"), "href") ==
             ["/manifest.webmanifest"]

    assert LazyHTML.attribute(
             LazyHTML.query(document, "meta[name=apple-mobile-web-app-title]"),
             "content"
           ) == ["Zipfelkasse"]

    assert document |> LazyHTML.query("meta[name=theme-color]") |> Enum.count() == 2
  end
end
