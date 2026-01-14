defmodule ChatService.Repo.Migrations.CreateWebhookLogs do
  use Ecto.Migration

  def change do
    create table(:webhook_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :request_id, :string, null: false
      add :event_type, :string, null: false
      add :payload, :map, default: %{}
      add :response, :map, default: %{}
      add :duration_ms, :integer
      add :status, :string, null: false
      add :error_message, :text
      add :user_id, :string
      add :ip_address, :string
      add :channel_id, references(:channels, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:webhook_logs, [:channel_id])
    create index(:webhook_logs, [:request_id])
    create index(:webhook_logs, [:event_type])
    create index(:webhook_logs, [:status])
    create index(:webhook_logs, [:inserted_at])
  end
end
