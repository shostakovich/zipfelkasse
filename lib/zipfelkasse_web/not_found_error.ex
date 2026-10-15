defmodule ZipfelkasseWeb.NotFoundError do
  @moduledoc "Something asked for that does not exist; its message heads the 404 page."
  defexception message: "Seite nicht gefunden.", plug_status: 404
end
