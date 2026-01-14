defmodule ChatService.Repo.Migrations.CreateAdmins do
  use Ecto.Migration

  def change do
    create table(:admins, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :password_hash, :string, null: false
      add :display_name, :string
      add :avatar_url, :string
      add :role, :string, default: "admin"
      add :token, :string

      timestamps()
    end

    create unique_index(:admins, [:email])
    create index(:admins, [:token])
  end
end
