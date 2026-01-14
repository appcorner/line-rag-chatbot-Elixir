defmodule ChatServiceWeb.CoreComponents do
  use Phoenix.Component
  use Gettext, backend: ChatServiceWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-4 right-4 z-50 space-y-2">
      <.flash kind={:info} title="Info" flash={@flash} />
      <.flash kind={:error} title="Error" flash={@flash} />
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :title, :string, default: nil
  attr :flash, :map, required: true
  attr :rest, :global

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      class={[
        "max-w-sm p-4 rounded-lg shadow-lg cursor-pointer",
        @kind == :info && "bg-blue-600 text-white",
        @kind == :error && "bg-red-600 text-white"
      ]}
      {@rest}
    >
      <p :if={@title} class="font-semibold"><%= @title %></p>
      <p><%= msg %></p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      class="hidden relative z-50"
    >
      <div class="fixed inset-0 bg-black/80" />
      <div class="fixed inset-0 overflow-y-auto">
        <div class="flex min-h-full items-center justify-center p-4">
          <div
            class="w-full max-w-lg bg-gray-800 rounded-xl p-6"
            phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
            phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
            phx-key="escape"
            data-cancel={hide_modal(@on_cancel, @id)}
          >
            <%= render_slot(@inner_block) %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["bg-gray-800 rounded-xl p-6 border border-gray-700", @class]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  attr :value, :integer, required: true
  attr :label, :string, required: true
  attr :color, :string, default: "blue"
  attr :icon, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class={["rounded-xl p-6", "bg-#{@color}-500/10 border border-#{@color}-500/30"]}>
      <div class="flex justify-between items-start">
        <div>
          <p class="text-gray-400 text-sm"><%= @label %></p>
          <p class="text-3xl font-bold text-white mt-1"><%= format_number(@value) %></p>
        </div>
        <div :if={@icon} class={["w-12 h-12 rounded-lg flex items-center justify-center", "bg-#{@color}-500/20"]}>
          <span class={["text-2xl", "text-#{@color}-400"]}><%= @icon %></span>
        </div>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true
  attr :label, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "px-2 py-1 rounded-full text-xs font-semibold",
      @status == :ok && "bg-green-500/20 text-green-400",
      @status == :warning && "bg-yellow-500/20 text-yellow-400",
      @status == :error && "bg-red-500/20 text-red-400"
    ]}>
      <%= @label %>
    </span>
    """
  end

  defp format_number(number) when number >= 1_000_000 do
    "#{Float.round(number / 1_000_000, 1)}M"
  end
  defp format_number(number) when number >= 1_000 do
    "#{Float.round(number / 1_000, 1)}K"
  end
  defp format_number(number), do: to_string(number)

  defp show_modal(id) do
    JS.show(to: "##{id}")
    |> JS.show(to: "##{id} > div:first-child", transition: {"ease-out duration-300", "opacity-0", "opacity-100"})
    |> JS.show(to: "##{id} > div:last-child > div", transition: {"ease-out duration-300", "opacity-0 scale-95", "opacity-100 scale-100"})
    |> JS.focus_first(to: "##{id} > div:last-child > div")
  end

  defp hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(to: "##{id} > div:first-child", transition: {"ease-in duration-200", "opacity-100", "opacity-0"})
    |> JS.hide(to: "##{id} > div:last-child > div", transition: {"ease-in duration-200", "opacity-100 scale-100", "opacity-0 scale-95"})
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.pop_focus()
  end

  defp hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition: {"transition-all transform ease-in duration-200", "opacity-100 translate-y-0", "opacity-0 -translate-y-4"}
    )
  end
end
