defmodule ChatService.Schemas.Admin do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "admins" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :display_name, :string
    field :avatar_url, :string
    field :role, :string, default: "admin"
    field :token, :string

    timestamps()
  end

  def changeset(admin, attrs) do
    admin
    |> cast(attrs, [:email, :password, :display_name, :avatar_url, :role])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:password, min: 6, message: "must be at least 6 characters")
    |> unique_constraint(:email)
    |> put_password_hash()
  end

  def update_changeset(admin, attrs) do
    admin
    |> cast(attrs, [:display_name, :avatar_url])
  end

  def password_changeset(admin, attrs) do
    admin
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 6, message: "must be at least 6 characters")
    |> put_password_hash()
  end

  def token_changeset(admin, token) do
    admin
    |> cast(%{token: token}, [:token])
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    # Simple hash using :crypto - in production use bcrypt or argon2
    hash = :crypto.hash(:sha256, password <> "chat_service_salt") |> Base.encode16(case: :lower)
    put_change(changeset, :password_hash, hash)
  end

  defp put_password_hash(changeset), do: changeset

  def verify_password(admin, password) do
    hash = :crypto.hash(:sha256, password <> "chat_service_salt") |> Base.encode16(case: :lower)
    admin.password_hash == hash
  end

  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
