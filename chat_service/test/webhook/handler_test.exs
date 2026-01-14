defmodule ChatService.Webhook.HandlerTest do
  use ExUnit.Case

  alias ChatService.Webhook.Handler

  describe "verify_signature/3" do
    test "returns error for nil signature" do
      assert {:error, :invalid_signature} = Handler.verify_signature("body", nil, "secret")
    end

    test "returns ok for valid signature" do
      body = ~s({"events":[]})
      secret = "test_secret"

      # Generate valid signature
      expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()

      assert :ok = Handler.verify_signature(body, expected, secret)
    end

    test "returns error for invalid signature" do
      body = ~s({"events":[]})
      secret = "test_secret"

      assert {:error, :invalid_signature} = Handler.verify_signature(body, "invalid", secret)
    end
  end
end
