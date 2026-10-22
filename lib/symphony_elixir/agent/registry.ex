defmodule SymphonyElixir.Agent.Registry do
  @moduledoc false

  alias SymphonyElixir.Agent.Implementers.Cursor

  @implementers %{
    "cursor" => Cursor
  }

  @spec fetch(String.t()) :: {:ok, module()} | {:error, {:unknown_agent, String.t()}}
  def fetch(name) when is_binary(name) do
    case Map.fetch(@implementers, name) do
      {:ok, implementer} -> {:ok, implementer}
      :error -> {:error, {:unknown_agent, name}}
    end
  end

  @spec validate_settings(map()) :: :ok | {:error, {:unknown_agent, String.t()}}
  def validate_settings(%{routing: routing, agents: agents}) do
    names =
      [routing.default_agent | Map.keys(agents) ++ Map.values(routing.by_label || %{})]
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    Enum.find_value(names, :ok, fn name ->
      case fetch(name) do
        {:ok, _implementer} -> nil
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def validate_settings(_settings), do: :ok

  @spec resolve(map(), map()) :: {:ok, map()} | {:error, {:unknown_agent, String.t()}}
  def resolve(settings, issue) when is_map(settings) and is_map(issue) do
    routing = settings.routing
    labels = Map.get(issue, :labels) || Map.get(issue, "labels") || []

    name =
      Enum.find_value(labels, routing.default_agent, fn label ->
        Map.get(routing.by_label, label) || Map.get(routing.by_label, String.downcase(to_string(label)))
      end)
      |> to_string()

    with {:ok, implementer} <- fetch(name) do
      config = Map.get(settings.agents, name, %{})

      {:ok,
       %{
         name: name,
         implementer: implementer,
         command: implementer.command(config)
       }}
    end
  end
end
