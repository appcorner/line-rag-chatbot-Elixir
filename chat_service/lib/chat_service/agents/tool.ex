defmodule ChatService.Agents.Tool do
  @moduledoc false

  @type params :: map()
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @type tool_definition :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @callback definition() :: tool_definition()

  @callback execute(params :: params()) :: result()

  @callback name() :: String.t()

  @callback enabled?() :: boolean()

  @optional_callbacks [enabled?: 0]
end
