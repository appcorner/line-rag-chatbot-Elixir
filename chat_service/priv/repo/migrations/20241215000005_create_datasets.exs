defmodule ChatService.Repo.Migrations.CreateDatasets do
  use Ecto.Migration

  def change do
    create table(:datasets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :collection_name, :string, null: false
      add :dimension, :integer, default: 1536
      add :metric, :string, default: "cosine"
      add :document_count, :integer, default: 0
      add :embedded_count, :integer, default: 0
      add :is_active, :boolean, default: true
      add :settings, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:datasets, [:name])
    create unique_index(:datasets, [:collection_name])
  end
end
