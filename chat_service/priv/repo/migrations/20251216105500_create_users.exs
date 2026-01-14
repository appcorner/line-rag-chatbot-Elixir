defmodule ChatService.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :line_user_id, :string, null: false
      add :display_name, :string
      add :picture_url, :text
      add :status_message, :text
      add :language, :string
      add :last_interaction_at, :utc_datetime
      add :metadata, :map, default: %{}
      add :channel_id, references(:channels, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:line_user_id, :channel_id])
    create index(:users, [:channel_id])
    create index(:users, [:last_interaction_at])
  end
end
