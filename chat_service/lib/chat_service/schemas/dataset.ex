defmodule ChatService.Schemas.Dataset do
  @moduledoc """
  Schema for storing dataset metadata.
  The actual vectors are stored in vector_service.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "datasets" do
    field :name, :string
    field :description, :string
    field :collection_name, :string  # Name in vector_service
    field :dimension, :integer, default: 1536  # OpenAI embedding dimension
    field :metric, :string, default: "cosine"
    field :document_count, :integer, default: 0
    field :embedded_count, :integer, default: 0
    field :is_active, :boolean, default: true
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name)a
  @optional_fields ~w(description collection_name dimension metric document_count embedded_count is_active settings)a

  def changeset(dataset, attrs) do
    dataset
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> maybe_generate_collection_name()
    |> unique_constraint(:name)
    |> unique_constraint(:collection_name)
  end

  defp maybe_generate_collection_name(changeset) do
    case get_field(changeset, :collection_name) do
      nil ->
        name = get_field(changeset, :name) || ""
        # Generate collection name: lowercase, replace spaces with underscores
        collection_name = name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "_")
          |> String.trim("_")

        put_change(changeset, :collection_name, "dataset_#{collection_name}_#{:rand.uniform(9999)}")
      _ ->
        changeset
    end
  end
end
