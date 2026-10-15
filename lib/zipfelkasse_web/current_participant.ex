defmodule ZipfelkasseWeb.CurrentParticipant do
  @moduledoc """
  The person using the app, chosen on /who and kept in the session as `participant_id`. A
  request without a known, active person is sent to /who, with the page to come back to; the
  `on_mount` hook does the same for the live session, whose socket outlives the first request.
  """

  @behaviour Plug

  import Plug.Conn

  alias Phoenix.{Component, LiveView}
  alias Plug.Conn.Query
  alias Zipfelkasse.Participants
  alias Zipfelkasse.Participants.Participant

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case from_session(get_session(conn)) do
      %Participant{} = participant ->
        assign(conn, :current_participant, participant)

      nil ->
        conn |> Phoenix.Controller.redirect(to: choice_path(conn)) |> halt()
    end
  end

  @doc "Assigns `current_participant` to a LiveView, or sends the visitor to /who."
  def on_mount(:default, params, session, socket) do
    socket = Component.assign_new(socket, :current_participant, fn -> from_session(session) end)

    case socket.assigns.current_participant do
      %Participant{archived_at: nil} -> {:cont, socket}
      _nobody -> {:halt, LiveView.redirect(socket, to: who_path(page_path(socket, params)))}
    end
  end

  # A live socket knows its route's params but not its path, so the router gives that back.
  defp page_path(%{router: router, view: view, assigns: %{live_action: action}}, params)
       when not is_nil(router) and is_map(params) do
    Enum.find_value(Phoenix.Router.routes(router), "/", fn
      %{path: path, metadata: %{phoenix_live_view: {^view, ^action, _opts, _session}}} ->
        fill(path, params)

      _route ->
        nil
    end)
  end

  defp page_path(_socket, _params), do: "/"

  defp fill(pattern, params) do
    {segments, query} =
      pattern
      |> String.split("/")
      |> Enum.map_reduce(params, fn
        ":" <> name, rest ->
          {URI.encode(params[name], &URI.char_unreserved?/1), Map.delete(rest, name)}

        segment, rest ->
          {segment, rest}
      end)

    path = Enum.join(segments, "/")
    if query == %{}, do: path, else: path <> "?" <> Query.encode(query)
  end

  @doc "The active person of a session, or nil."
  def from_session(%{"participant_id" => id}) when is_integer(id) do
    case Participants.get_participant(id) do
      %Participant{archived_at: nil} = participant -> participant
      _unknown_or_archived -> nil
    end
  end

  def from_session(_session), do: nil

  @doc "Where to choose a person; a GET of a page other than the start page comes back to it."
  def choice_path(%Plug.Conn{method: "GET", request_path: path} = conn) when path != "/" do
    who_path(if conn.query_string == "", do: path, else: path <> "?" <> conn.query_string)
  end

  def choice_path(_conn), do: "/who"

  defp who_path("/"), do: "/who"
  defp who_path(target), do: "/who?" <> URI.encode_query(%{"return_to" => target})
end
