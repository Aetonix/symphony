defmodule SymphonyElixir.AcpTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{AcpClient, Branch, Registry, ToolBroker}
  alias SymphonyElixir.JSON

  test "json encoding replaces invalid utf-8" do
    invalid = "ok" <> <<0xFF, 0xFE>> <> "tail"

    encoded = JSON.encode!(%{"text" => invalid})

    assert encoded =~ "ok"
    assert encoded =~ "tail"
    assert {:ok, %{"text" => text}} = Jason.decode(encoded)
    assert String.valid?(text)
    assert text =~ "\uFFFD"
  end

  test "branch names come from the tracker or the ticket" do
    assert Branch.name(%{branch_name: "refs/heads/origin/Feature/One"}) == "Feature/One"

    assert Branch.name(%{identifier: "MT-7", title: "Fix the prompt!"}) == "MT-7-fix-the-prompt"

    assert Branch.base(%{workspace: %{base_branch: "dev"}}) == "dev"
    assert Branch.base(nil) == "main"
  end

  test "registry rejects an agent name with no implementer" do
    settings = %{routing: %{default_agent: "claude", by_label: %{}}, agents: %{}}

    assert {:error, {:unknown_agent, "claude"}} = Registry.validate_settings(settings)
  end

  test "registry resolves the cursor implementer from the workflow" do
    assert {:ok, %{name: "cursor", command: command}} =
             Registry.resolve(Config.settings!(), %{labels: []})

    assert command =~ "codex app-server"
  end

  test "tool broker lists tools without exposing the tracker token" do
    binding = %{
      tool_specs: [%{"name" => "linear_graphql"}],
      secret_environment_names: ["LINEAR_API_KEY"]
    }

    assert :ok = ToolBroker.ensure_started()
    assert {:ok, token, port} = ToolBroker.register(binding)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    request =
      JSON.encode!(%{
        "token" => token,
        "message" => %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
      })

    :ok = :gen_tcp.send(socket, request <> "\n")
    assert {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    assert {:ok, %{"result" => %{"tools" => tools}}} = Jason.decode(line)
    assert Enum.any?(tools, &(&1["name"] == "linear_graphql"))
    refute line =~ "LINEAR_API_KEY"

    unknown =
      JSON.encode!(%{
        "token" => "nope",
        "message" => %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}
      })

    :ok = :gen_tcp.send(socket, unknown <> "\n")
    assert {:ok, denied} = :gen_tcp.recv(socket, 0, 2_000)
    assert denied =~ "unknown tool session"
    :gen_tcp.close(socket)
  end

  test "acp client opens a session and runs one prompt" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(test_root)
      fake = Path.join(test_root, "fake-agent")
      trace = Path.join(test_root, "agent.trace")

      File.write!(fake, """
      #!/bin/sh
      trace_file="#{trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf '%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"sessionId":"sess-1"}}'
            ;;
          3)
            printf '%s\\n' '{"method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"text":"thinking"}}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","id":9,"method":"session/request_permission","params":{"toolCall":{"title":"shell"},"options":[{"optionId":"allow-once"}]}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"stopReason":"end_turn"}}'
            ;;
        esac
      done
      """)

      File.chmod!(fake, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(), codex_command: fake)

      parent = self()

      on_message = fn message ->
        send(parent, {:agent_message, message})
      end

      assert {:ok, session} = AcpClient.start_session(test_root, issue: %{labels: []})
      assert session.session_id == "sess-1"

      assert {:ok, %{session_id: "sess-1-1"}} =
               AcpClient.run_prompt(session, "hello", %{}, on_message: on_message, prompt_number: 1)

      assert :ok = AcpClient.stop_session(session)

      assert_receive {:agent_message, %{event: :prompt_started, session_id: "sess-1-1"}}
      assert_receive {:agent_message, %{event: :session_update, kind: "thought", text: "thinking"}}
      assert_receive {:agent_message, %{event: :permission, kind: "tool", text: "Allowed shell"}}
      assert_receive {:agent_message, %{event: :prompt_completed}}

      trace_body = File.read!(trace)
      assert trace_body =~ "\"method\":\"session/new\""
      assert trace_body =~ "\"method\":\"session/prompt\""
      refute trace_body =~ "LINEAR_API_KEY"
    after
      File.rm_rf(test_root)
    end
  end
end
