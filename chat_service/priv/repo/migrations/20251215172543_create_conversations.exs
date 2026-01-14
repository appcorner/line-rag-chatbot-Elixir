defmodule ChatService.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :channel_id, :string, null: false
      add :user_id, :string, null: false
      add :status, :string, default: "active"
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:conversations, [:channel_id])
    create index(:conversations, [:user_id])
    create index(:conversations, [:channel_id, :user_id])

    # Add conversation_id and role to messages if not exists
    alter table(:messages) do
      add_if_not_exists :conversation_id, references(:conversations, type: :binary_id, on_delete: :delete_all)
      add_if_not_exists :role, :string, default: "user"
    end
  end
end
