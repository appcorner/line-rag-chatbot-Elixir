defmodule ChatService.Schemas.Document do
  @moduledoc """
  Schema for storing document metadata.
  Vectors are stored in vector_service, metadata is stored here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "documents" do
    field :vector_id, :string  # ID in vector_service
    field :question, :string
    field :answer, :string
    field :content, :string    # For non-FAQ documents
    field :doc_type, :string, default: "faq"
    field :metadata, :map, default: %{}
    field :status, :string, default: "indexed"

    belongs_to :dataset, ChatService.Schemas.Dataset

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(dataset_id vector_id)a
  @optional_fields ~w(question answer content doc_type metadata status)a

  def changeset(document, attrs) do
    document
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:dataset_id)
  end
end
