defmodule ChatService.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :direction, :string, null: false
      add :content, :text, null: false
      add :message_type, :string, default: "text"
      add :reply_token, :string
      add :line_message_id, :string
      add :metadata, :map, default: %{}
      add :channel_id, references(:channels, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:channel_id])
    create index(:messages, [:user_id])
    create index(:messages, [:inserted_at])
    create index(:messages, [:channel_id, :user_id])
  end
end
