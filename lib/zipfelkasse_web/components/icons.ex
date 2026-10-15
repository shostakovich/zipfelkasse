defmodule ZipfelkasseWeb.Icons do
  @moduledoc """
  The app's Lucide icons, compiled from the SVG files in `assets/vendor/lucide` (lucide-static,
  ISC licence). `<.icon name="…">` from Setzkasten looks names up here first, then in the icons
  Setzkasten ships itself; an unknown name raises.

  To add an icon, copy `icons/<name>.svg` from lucide-static into the directory.
  """
  use Setzkasten.Icons, path: "assets/vendor/lucide"
end
