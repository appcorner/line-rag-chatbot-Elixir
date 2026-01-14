defmodule ChatService.Schemas.WebhookLog do
  @moduledoc """
  Schema for storing webhook request/response logs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "webhook_logs" do
    field :request_id, :string
    field :event_type, :string
    field :payload, :map, default: %{}
    field :response, :map, default: %{}
    field :duration_ms, :integer
    field :status, Ecto.Enum, values: [:success, :error, :timeout]
    field :error_message, :string
    field :user_id, :string
    field :ip_address, :string

    belongs_to :channel, ChatService.Schemas.Channel

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(request_id event_type status channel_id)a
  @optional_fields ~w(payload response duration_ms error_message user_id ip_address)a

  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:channel_id)
  end
end
