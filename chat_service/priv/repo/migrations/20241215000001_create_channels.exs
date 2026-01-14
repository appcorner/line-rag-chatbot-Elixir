defmodule ChatService.Repo.Migrations.CreateChannels do
  use Ecto.Migration

  def change do
    create table(:channels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :channel_id, :string, null: false
      add :name, :string, null: false
      add :access_token, :text, null: false
      add :channel_secret, :string, null: false
      add :settings, :map, default: %{}
      add :is_active, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:channels, [:channel_id])
    create index(:channels, [:is_active])
  end
end
