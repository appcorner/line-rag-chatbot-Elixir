defmodule ChatServiceTest do
  use ExUnit.Case

  describe "version/0" do
    test "returns version string" do
      assert is_binary(ChatService.version())
    end
  end

  describe "backend_url/0" do
    test "returns backend URL" do
      url = ChatService.backend_url()
      assert String.starts_with?(url, "http")
    end
  end

  describe "port/0" do
    test "returns port number" do
      port = ChatService.port()
      assert is_integer(port)
      assert port > 0
    end
  end
end
