defmodule ChatService.Schemas.Message do
  @moduledoc """
  Schema for storing message history.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field :user_id, :string
    field :direction, Ecto.Enum, values: [:incoming, :outgoing]
    field :role, :string, default: "user"
    field :content, :string
    field :message_type, :string, default: "text"
    field :reply_token, :string
    field :line_message_id, :string
    field :metadata, :map, default: %{}
    field :is_read, :boolean, default: false
    field :read_at, :utc_datetime

    belongs_to :channel, ChatService.Schemas.Channel
    belongs_to :conversation, ChatService.Schemas.Conversation

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(user_id direction content channel_id)a
  @optional_fields ~w(message_type reply_token line_message_id metadata conversation_id role is_read read_at)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:channel_id)
  end
end
