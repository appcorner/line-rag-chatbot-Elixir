defmodule ChatServiceWeb.PageController do
  use ChatServiceWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/dashboard")
  end
end
