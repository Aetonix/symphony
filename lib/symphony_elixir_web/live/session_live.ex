defmodule SymphonyElixirWeb.SessionLive do
  @moduledoc """
  Live session view for one issue: reasoning, assistant text, and tool summaries.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.ObservabilityPubSub

  @impl true
  def mount(%{"issue_identifier" => identifier}, _session, socket) do
    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

    {:ok,
     socket
     |> assign(:issue_identifier, identifier)
     |> assign(:show_raw, false)
     |> assign_session()}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign_session(socket)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_raw", _params, socket) do
    {:noreply, assign(socket, :show_raw, not socket.assigns.show_raw)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="page">
      <section class="hero-card">
        <p class="eyebrow">Session</p>
        <h1><%= @issue_identifier %></h1>
        <p class="lede">
          <%= if @live? do %>
            Live session <%= @session_id %>
          <% else %>
            <%= if @events == [] do %>
              No session is available for this issue.
            <% else %>
              Saved session <%= @session_id %>
            <% end %>
          <% end %>
        </p>
        <p><a class="issue-link" href="/">Back to dashboard</a></p>
        <button type="button" phx-click="toggle_raw">
          <%= if @show_raw, do: "Hide raw events", else: "Show raw events" %>
        </button>
      </section>

      <section class="section-card">
        <div :if={@events == []} class="empty">Waiting for the first prompt.</div>
        <article :for={event <- @events} class={"session-event session-event-#{event.kind}"}>
          <p class="session-kind"><%= event.kind %></p>
          <p class="session-text"><%= event.text %></p>
          <pre :if={@show_raw} class="session-raw"><%= raw_event(event) %></pre>
        </article>
      </section>
    </main>
    """
  end

  defp assign_session(socket) do
    identifier = socket.assigns.issue_identifier
    {events, session_id, live?} = lookup(identifier)

    socket
    |> assign(:events, events)
    |> assign(:session_id, session_id)
    |> assign(:live?, live?)
  end

  defp lookup(identifier) do
    case Orchestrator.snapshot() do
      %{running: running, session_histories: histories} ->
        lookup_running(running, histories, identifier)

      _ ->
        {[], nil, false}
    end
  end

  defp lookup_running(running, histories, identifier) do
    case Enum.find(running, &(Map.get(&1, :identifier) == identifier)) do
      %{session_events: events, session_id: session_id} ->
        {normalize_events(events), session_id, true}

      _ ->
        lookup_history(histories, identifier)
    end
  end

  defp lookup_history(histories, identifier) do
    case Map.get(histories, identifier) do
      %{events: events, session_id: session_id} ->
        {normalize_events(events), session_id, false}

      _ ->
        {[], nil, false}
    end
  end

  defp normalize_events(events) do
    Enum.map(events, fn event ->
      %{
        kind: to_string(Map.get(event, :kind) || "status"),
        text: to_string(Map.get(event, :text) || ""),
        raw: Map.get(event, :raw)
      }
    end)
  end

  defp raw_event(event) do
    SymphonyElixir.JSON.encode!(event.raw || %{}, pretty: true)
  rescue
    _error -> inspect(event.raw)
  end
end
