defmodule Zipfelkasse.Ynab.Connection do
  @moduledoc """
  A person's connection to YNAB: the personal access token, the plan and account the shares go
  to, and the state of the last sync.
  """

  use Zipfelkasse.Schema

  alias Zipfelkasse.Participants.Participant

  @type t :: %__MODULE__{}

  @primary_key false
  schema "ynab_connections" do
    belongs_to :participant, Participant, primary_key: true
    field :token, :string, redact: true
    field :plan_id, :string
    field :account_id, :string
    field :start_date, :date
    field :connected_at, :utc_datetime_usec
    field :last_run_at, :utc_datetime_usec
    field :last_synced_at, :utc_datetime_usec
    field :summary, :string
    field :error, :string
    field :token_invalid, :boolean, default: false
    field :retry_at, :utc_datetime_usec
    field :backoff_seconds, :integer, default: 0

    timestamps()
  end
end
