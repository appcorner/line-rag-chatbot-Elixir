defmodule ChatService.Repo.Migrations.AddDatasetToChannels do
  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :dataset_id, references(:datasets, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:channels, [:dataset_id])
  end
end
