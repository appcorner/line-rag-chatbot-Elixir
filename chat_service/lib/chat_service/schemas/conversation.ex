defmodule ChatService.Schemas.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field :channel_id, :string
    field :user_id, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    has_many :messages, ChatService.Schemas.Message

    timestamps(type: :utc_datetime)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:channel_id, :user_id, :status, :metadata])
    |> validate_required([:channel_id, :user_id])
  end
end
