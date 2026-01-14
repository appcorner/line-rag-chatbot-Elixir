defmodule ChatService.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :dataset_id, references(:datasets, type: :binary_id, on_delete: :delete_all), null: false
      add :vector_id, :string, null: false  # ID in vector_service
      add :question, :text
      add :answer, :text
      add :content, :text  # For non-FAQ documents
      add :doc_type, :string, default: "faq"
      add :metadata, :map, default: %{}
      add :status, :string, default: "indexed"

      timestamps(type: :utc_datetime)
    end

    create index(:documents, [:dataset_id])
    create index(:documents, [:vector_id])
  end
end
