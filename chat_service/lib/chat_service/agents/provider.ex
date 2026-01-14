defmodule ChatService.Agents.Provider do
  @moduledoc false

  @type message :: %{
          role: String.t(),
          content: String.t(),
          tool_calls: list() | nil,
          tool_call_id: String.t() | nil
        }

  @type tool :: %{
          type: String.t(),
          function: %{
            name: String.t(),
            description: String.t(),
            parameters: map()
          }
        }

  @type completion_result :: %{
          content: String.t() | nil,
          tool_calls: list(),
          usage: map() | nil
        }

  @type config :: %{
          api_key: String.t(),
          model: String.t(),
          temperature: float(),
          max_tokens: integer()
        }

  @callback chat(messages :: [message()], tools :: [tool()], config :: config()) ::
              {:ok, completion_result()} | {:error, term()}

  @callback name() :: String.t()

  @callback default_model() :: String.t()

  @callback available_models() :: [String.t()]

  @callback validate_api_key(api_key :: String.t()) :: :ok | {:error, String.t()}

  @optional_callbacks [validate_api_key: 1]
end
