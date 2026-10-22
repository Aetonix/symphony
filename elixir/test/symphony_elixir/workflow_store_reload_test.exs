defmodule SymphonyElixir.WorkflowStoreReloadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "invalid workflow reload is rejected by schema" do
    assert {:error, {:invalid_workflow_config, _message}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "linear", "api_key" => "x", "project_slug" => "p"},
               "agent" => %{"max_concurrent_agents" => -1}
             })
  end

  test "valid workflow accepts in-flight cap fields during reload" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "linear", "api_key" => "x", "project_slug" => "p"},
               "agent" => %{"max_concurrent_agents" => 2, "max_turns" => 5},
               "server" => %{"host" => "127.0.0.1", "port" => 4000}
             })

    assert settings.agent.max_concurrent_agents == 2
  end
end
