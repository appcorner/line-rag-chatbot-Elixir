defmodule ChatService.Repo.Migrations.AddMessageReadStatus do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :is_read, :boolean, default: false
      add :read_at, :utc_datetime
    end

    # Add user tags/notes
    alter table(:users) do
      add :tags, {:array, :string}, default: []
      add :notes, :text
      add :is_blocked, :boolean, default: false
    end

    create index(:messages, [:is_read])
    create index(:messages, [:user_id, :is_read])
  end
end
