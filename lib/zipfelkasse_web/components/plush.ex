defmodule ZipfelkasseWeb.Plush do
  @moduledoc """
  The plush images for `<.plush>`, the shell's nav entries and `<.empty_state plush="…">` from
  Setzkasten: one WebP per motif in `priv/static/images/plush`, named after its Lucide icon, the
  same in both themes.
  """
  @behaviour Setzkasten.Plush

  @names ~w(activity archive baby banknote car gift graduation-cap heart house key paw-print
            plane receipt repeat scale settings shield shirt shopping-cart smartphone tag ticket
            users utensils wallet zap)

  @doc "The motifs there are images of."
  def names, do: @names

  @impl true
  def src(name, :light) when name in @names,
    do: ZipfelkasseWeb.Endpoint.static_path("/images/plush/#{name}.webp")

  def src(_name, _variant), do: nil
end
