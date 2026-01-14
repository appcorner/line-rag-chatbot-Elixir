defmodule ChatService.Schemas.Channel do
  @moduledoc """
  Schema for LINE channels configuration.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "channels" do
    field :channel_id, :string
    field :name, :string
    field :access_token, :string
    field :channel_secret, :string
    field :settings, :map, default: %{}
    field :is_active, :boolean, default: true

    belongs_to :dataset, ChatService.Schemas.Dataset
    has_many :messages, ChatService.Schemas.Message
    has_many :webhook_logs, ChatService.Schemas.WebhookLog

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(channel_id name access_token channel_secret)a
  @optional_fields ~w(settings is_active dataset_id)a

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:channel_id)
  end
end
