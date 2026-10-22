defmodule SymphonyElixir.Agent.Implementers.Cursor do
  @moduledoc false

  @auth_method_id "cursor_login"

  @spec command(map()) :: String.t()
  def command(config) when is_map(config) do
    Map.get(config, "command") || Map.get(config, :command) || "agent acp"
  end

  @spec auth_method_id() :: String.t()
  def auth_method_id, do: @auth_method_id
end
