defmodule ChatServiceWeb.AdminController do
  use ChatServiceWeb, :controller

  alias ChatService.Repo
  alias ChatService.Schemas.Admin

  def login(conn, %{"email" => email, "password" => password}) do
    case Repo.get_by(Admin, email: email) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{detail: "Invalid email or password"})

      admin ->
        if Admin.verify_password(admin, password) do
          token = Admin.generate_token()
          {:ok, admin} = admin |> Admin.token_changeset(token) |> Repo.update()

          json(conn, %{
            accessToken: token,
            admin: format_admin(admin)
          })
        else
          conn
          |> put_status(:unauthorized)
          |> json(%{detail: "Invalid email or password"})
        end
    end
  end

  def register(conn, %{"email" => email, "password" => password, "displayName" => display_name}) do
    attrs = %{
      email: email,
      password: password,
      display_name: display_name
    }

    changeset = Admin.changeset(%Admin{}, attrs)

    case Repo.insert(changeset) do
      {:ok, admin} ->
        token = Admin.generate_token()
        {:ok, admin} = admin |> Admin.token_changeset(token) |> Repo.update()

        conn
        |> put_status(:created)
        |> json(%{
          accessToken: token,
          admin: format_admin(admin)
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{detail: format_errors(changeset)})
    end
  end

  def me(conn, %{"token" => token}) do
    case Repo.get_by(Admin, token: token) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{detail: "Invalid or expired token"})

      admin ->
        json(conn, format_admin(admin))
    end
  end

  def update_me(conn, %{"token" => token} = params) do
    case Repo.get_by(Admin, token: token) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{detail: "Invalid or expired token"})

      admin ->
        attrs = %{}
        attrs = if params["displayName"], do: Map.put(attrs, :display_name, params["displayName"]), else: attrs

        case admin |> Admin.update_changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            json(conn, format_admin(updated))

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{detail: format_errors(changeset)})
        end
    end
  end

  def upload_avatar(conn, %{"token" => token}) do
    case Repo.get_by(Admin, token: token) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{detail: "Invalid or expired token"})

      admin ->
        avatar_url = "/uploads/avatars/#{admin.id}.png"

        case admin |> Admin.update_changeset(%{avatar_url: avatar_url}) |> Repo.update() do
          {:ok, updated} ->
            json(conn, format_admin(updated))

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{detail: "Failed to update avatar"})
        end
    end
  end

  def change_password(conn, %{"token" => token, "currentPassword" => current, "newPassword" => new_password}) do
    case Repo.get_by(Admin, token: token) do
      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{detail: "Invalid or expired token"})

      admin ->
        if Admin.verify_password(admin, current) do
          case admin |> Admin.password_changeset(%{password: new_password}) |> Repo.update() do
            {:ok, _} ->
              json(conn, %{message: "Password changed successfully"})

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{detail: format_errors(changeset)})
          end
        else
          conn
          |> put_status(:unauthorized)
          |> json(%{detail: "Current password is incorrect"})
        end
    end
  end

  defp format_admin(admin) do
    %{
      id: admin.id,
      email: admin.email,
      displayName: admin.display_name,
      avatarUrl: admin.avatar_url,
      role: admin.role,
      createdAt: admin.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
  end
end
