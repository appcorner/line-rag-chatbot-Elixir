defmodule ChatService.Services.User.Service do
  @moduledoc false

  require Logger

  alias ChatService.Repo
  alias ChatService.Schemas.User
  alias ChatService.Services.Line.Api, as: LineApi
  import Ecto.Query

  @doc """
  Get or create a user, fetching profile from LINE if needed.
  Returns {:ok, user} or {:error, reason}
  """
  def get_or_create_user(line_user_id, channel) do
    case get_user(line_user_id, channel.id) do
      {:ok, user} ->
        # Update last interaction time
        update_last_interaction(user)
        {:ok, user}

      {:error, :not_found} ->
        # Fetch profile from LINE and create user
        create_user_with_profile(line_user_id, channel)
    end
  end

  @doc """
  Get a user by LINE user ID and channel.
  """
  def get_user(line_user_id, channel_id) do
    case User
         |> where([u], u.line_user_id == ^line_user_id and u.channel_id == ^channel_id)
         |> Repo.one() do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  List users for a channel.
  """
  def list_users(channel_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    User
    |> where([u], u.channel_id == ^channel_id)
    |> order_by([u], desc: u.last_interaction_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Refresh user profile from LINE API.
  """
  def refresh_profile(user, access_token) do
    case LineApi.get_profile(user.line_user_id, access_token) do
      {:ok, profile} ->
        update_user(user, %{
          display_name: profile.display_name,
          picture_url: profile.picture_url,
          status_message: profile.status_message,
          language: profile.language
        })

      {:error, reason} ->
        Logger.warning("Failed to refresh profile for #{user.line_user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Count total users for a channel.
  """
  def count_users(channel_id) do
    User
    |> where([u], u.channel_id == ^channel_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Count total users across all channels.
  """
  def count_all_users do
    Repo.aggregate(User, :count, :id)
  end

  # Private functions

  defp create_user_with_profile(line_user_id, channel) do
    # First try to fetch profile from LINE
    profile_attrs =
      case LineApi.get_profile(line_user_id, channel.access_token) do
        {:ok, profile} ->
          Logger.info("Fetched LINE profile for user #{line_user_id}: #{profile.display_name}")
          %{
            display_name: profile.display_name,
            picture_url: profile.picture_url,
            status_message: profile.status_message,
            language: profile.language
          }

        {:error, reason} ->
          Logger.warning("Could not fetch LINE profile for #{line_user_id}: #{inspect(reason)}")
          %{}
      end

    # Create user with whatever profile info we got
    attrs =
      Map.merge(profile_attrs, %{
        line_user_id: line_user_id,
        channel_id: channel.id,
        last_interaction_at: DateTime.utc_now()
      })

    case %User{} |> User.changeset(attrs) |> Repo.insert() do
      {:ok, user} ->
        Logger.info("Created new user: #{user.line_user_id} (#{user.display_name || "no name"})")
        {:ok, user}

      {:error, changeset} ->
        Logger.error("Failed to create user: #{inspect(changeset.errors)}")
        {:error, :create_failed}
    end
  end

  defp update_last_interaction(user) do
    user
    |> User.changeset(%{last_interaction_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end
end
