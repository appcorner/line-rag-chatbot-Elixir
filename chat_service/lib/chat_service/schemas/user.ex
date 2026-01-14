defmodule ChatService.Schemas.User do
  @moduledoc """
  Schema for storing LINE user profiles.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :line_user_id, :string
    field :display_name, :string
    field :picture_url, :string
    field :status_message, :string
    field :language, :string
    field :last_interaction_at, :utc_datetime
    field :metadata, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :notes, :string
    field :is_blocked, :boolean, default: false

    belongs_to :channel, ChatService.Schemas.Channel
    has_many :messages, ChatService.Schemas.Message, foreign_key: :user_id, references: :line_user_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(line_user_id channel_id)a
  @optional_fields ~w(display_name picture_url status_message language last_interaction_at metadata tags notes is_blocked)a

  def changeset(user, attrs) do
    user
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:line_user_id, :channel_id])
  end
end
