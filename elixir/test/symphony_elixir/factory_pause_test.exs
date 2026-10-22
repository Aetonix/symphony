defmodule SymphonyElixir.FactoryPauseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  @base_config %{
    "tracker" => %{
      "kind" => "linear",
      "api_key" => "test",
      "project_slug" => "demo",
      "oauth_read_only" => true
    },
    "agent" => %{"max_concurrent_agents" => 0},
    "server" => %{"host" => "127.0.0.1", "port" => 4000}
  }

  test "accepts max_concurrent_agents 0 for factory pause" do
    assert {:ok, settings} = Schema.parse(@base_config)
    assert settings.agent.max_concurrent_agents == 0
    assert settings.tracker.oauth_read_only == true
  end

  test "accepts paused flag without dispatch" do
    config = Map.put(@base_config, "paused", true)
    assert {:ok, settings} = Schema.parse(config)
    assert settings.paused == true
  end

  test "rejects non-localhost server host" do
    config = put_in(@base_config, ["server", "host"], "0.0.0.0")
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(config)
  end
end
