defmodule ZipfelkasseWeb.CoreComponents do
  @moduledoc """
  The app's own pieces next to Setzkasten's components (`use Setzkasten` in `ZipfelkasseWeb`):
  the German texts of Ecto's validation messages, local times, activity entries, the rename form
  of people and categories, and numbers of expenses.
  """
  use Phoenix.Component
  use Setzkasten
  use ZipfelkasseWeb, :verified_routes

  alias Phoenix.LiveView.JS
  alias Setzkasten.Format
  alias Zipfelkasse.Activities.Activity
  alias Zipfelkasse.LocalTime

  @doc "A UTC moment in local time, `14.10.2026, 18:05`, machine-readable in `datetime`."
  attr :at, DateTime, required: true
  attr :class, :any, default: nil

  def local_time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(DateTime.truncate(@at, :second))} class={@class}>
      {Format.datetime(LocalTime.from_utc(@at))}
    </time>
    """
  end

  @doc """
  An entry of the activity log as a list row: who did what, the changed fields as old → new, and
  when. With `link` an entry about an expense opens it.
  """
  attr :id, :string, required: true
  attr :activity, Activity, required: true
  attr :link, :boolean, default: false

  def activity_entry(assigns) do
    activity = assigns.activity

    assigns =
      assign(assigns,
        actor: if(activity.actor, do: activity.actor.name, else: "Automatisch"),
        verb: verb(activity.action),
        details: activity.details,
        amount?: activity.action in [:expense_created, :expense_deleted],
        path: if(assigns.link && activity.expense_id, do: ~p"/expenses/#{activity.expense_id}")
      )

    ~H"""
    <.list_row id={@id} navigate={@path}>
      <%= if @verb do %>
        {@actor} hat „{@details.title}“ {@verb}<span
          :if={@amount? && @details.amount_cents}
          class="font-normal text-base-content/70"
        > (<.amount value={@details.amount_cents} />)</span>.
      <% else %>
        {@actor}: {@details.text || @activity.action}
      <% end %>
      <span
        :for={change <- @details.changes}
        class="mt-1 block text-sm font-normal text-base-content/70"
      >
        {change.field}: <del>{blank(change.old)}</del>
        → <ins class="text-base-content no-underline">{blank(change.new)}</ins>
      </span>
      <:meta><.local_time at={@activity.inserted_at} /></:meta>
    </.list_row>
    """
  end

  defp verb(:expense_created), do: "angelegt"
  defp verb(:expense_updated), do: "geändert"
  defp verb(:expense_deleted), do: "gelöscht"
  defp verb(_action), do: nil

  defp blank(value) when value in [nil, ""], do: "–"
  defp blank(value), do: value

  @doc """
  The name form of a person or category in a popover at its row, open while the page renders it.
  It sends `validate_rename` and `save_rename` with the params under `rename`, and
  `cancel_rename` when it closes otherwise.
  """
  attr :id, :string, required: true
  attr :name, :string, required: true, doc: "the current name, for the title"
  attr :anchor, :string, required: true, doc: "the id of the row"
  attr :form, Phoenix.HTML.Form, required: true

  def rename_popover(assigns) do
    ~H"""
    <.popover
      id={@id}
      title={"„#{@name}“ umbenennen"}
      anchor={@anchor}
      align={:end}
      show
      on_cancel={JS.push("cancel_rename")}
    >
      <.form
        for={@form}
        id="rename-form"
        class="grid gap-3"
        phx-change="validate_rename"
        phx-submit="save_rename"
      >
        <.input
          field={@form[:name]}
          label="Name"
          required
          maxlength={Zipfelkasse.Names.max_length()}
          autocomplete="off"
          autofocus
        />
        <div class="flex justify-end gap-2">
          <.button size={:sm} phx-click={hide_popover(@id)}>Abbrechen</.button>
          <.button type="submit" size={:sm} variant={:primary}>Speichern</.button>
        </div>
      </.form>
    </.popover>
    """
  end

  @doc ~s(A number of expenses: `"1 Ausgabe"`, `"3 Ausgaben"`.)
  @spec expense_count(non_neg_integer()) :: String.t()
  def expense_count(1), do: "1 Ausgabe"
  def expense_count(count), do: "#{count} Ausgaben"

  @doc "German messages from the validation pass through; Ecto's English ones are looked up."
  @spec translate_error({String.t(), keyword}) :: String.t()
  def translate_error({msg, opts}) do
    # unique_constraint/3 marks its error with `constraint: :unique`, not a validation.
    (Keyword.get(opts, :validation) || Keyword.get(opts, :constraint))
    |> german(msg, opts)
    |> interpolate(opts)
  end

  defp german(:required, "can't be blank", _opts), do: "muss ausgefüllt werden"
  defp german(:inclusion, "is invalid", _opts), do: "ist kein gültiger Wert"
  defp german(:exclusion, "is reserved", _opts), do: "ist nicht erlaubt"
  defp german(:format, "has invalid format", _opts), do: "hat ein ungültiges Format"
  defp german(:cast, "is invalid", _opts), do: "ist ungültig"
  defp german(:unique, "has already been taken", _opts), do: "ist bereits vergeben"
  defp german(:acceptance, "must be accepted", _opts), do: "muss akzeptiert werden"
  defp german(:confirmation, "does not match" <> _, _opts), do: "stimmt nicht überein"

  defp german(:number, "must be " <> _, opts) do
    case Keyword.get(opts, :kind) do
      :less_than -> "muss kleiner als %{number} sein"
      :greater_than -> "muss größer als %{number} sein"
      :less_than_or_equal_to -> "darf höchstens %{number} sein"
      :greater_than_or_equal_to -> "muss mindestens %{number} sein"
      :equal_to -> "muss %{number} sein"
      :not_equal_to -> "darf nicht %{number} sein"
    end
  end

  defp german(:length, "should be " <> _, opts) do
    case {Keyword.get(opts, :type), Keyword.get(opts, :kind)} do
      {:list, :min} -> "braucht mindestens %{count} Einträge"
      {:list, :max} -> "darf höchstens %{count} Einträge haben"
      {:list, :is} -> "braucht genau %{count} Einträge"
      {_, :min} -> "muss mindestens %{count} Zeichen lang sein"
      {_, :max} -> "darf höchstens %{count} Zeichen lang sein"
      {_, :is} -> "muss genau %{count} Zeichen lang sein"
    end
  end

  defp german(_validation, msg, _opts), do: msg

  defp interpolate(msg, opts) do
    Regex.replace(~r/%{(\w+)}/, msg, fn whole, key -> option_text(opts, key, whole) end)
  end

  defp option_text(opts, key, fallback) do
    case Enum.find(opts, fn {name, _} -> Atom.to_string(name) == key end) do
      {_, value} -> to_string(value)
      nil -> fallback
    end
  end
end
