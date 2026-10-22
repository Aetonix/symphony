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

    assert {:ok, %{"result" => %{"tools" => tools}}} = post_mcp(port, token, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    assert Enum.any?(tools, &(&1["name"] == "linear_graphql"))

    assert {:ok, 401, denied} = post_mcp_raw(port, "nope", %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
    assert denied =~ "unknown tool session"
    refute denied =~ "LINEAR_API_KEY"
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
            printf '%s\\n' '{"id":1,"result":{"agentCapabilities":{"mcpCapabilities":{"http":true}}}}'
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
      assert trace_body =~ "\"type\":\"http\""
      assert trace_body =~ "/mcp"
      assert trace_body =~ "\"method\":\"session/prompt\""
      refute trace_body =~ "LINEAR_API_KEY"
      refute trace_body =~ "agent_tool_proxy"
    after
      File.rm_rf(test_root)
    end
  end

  test "acp client rejects an agent without http mcp" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-nohttp-#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(test_root)
      fake = Path.join(test_root, "fake-agent")

      File.write!(fake, """
      #!/bin/sh
      while IFS= read -r line; do
        printf '%s\\n' '{"id":1,"result":{"agentCapabilities":{"mcpCapabilities":{"http":false}}}}'
        exit 0
      done
      """)

      File.chmod!(fake, 0o755)
      write_workflow_file!(Workflow.workflow_file_path(), codex_command: fake)

      assert {:error, :agent_http_mcp_required} = AcpClient.start_session(test_root, issue: %{labels: []})
    after
      File.rm_rf(test_root)
    end
  end

  defp post_mcp(port, token, message) do
    {:ok, 200, body} = post_mcp_raw(port, token, message)
    Jason.decode(body)
  end

  defp post_mcp_raw(port, token, message) do
    body = JSON.encode!(message)

    request = [
      "POST /mcp HTTP/1.1\r\n",
      "Host: 127.0.0.1\r\n",
      "Authorization: Bearer #{token}\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Connection: close\r\n",
      "\r\n",
      body
    ]

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = recv_all(socket, "")
    :gen_tcp.close(socket)
    [head, resp_body] = String.split(response, "\r\n\r\n", parts: 2)
    ["HTTP/1.1 " <> status | _] = String.split(head, "\r\n")
    {code, _} = Integer.parse(status)
    {:ok, code, resp_body}
  end

  defp recv_all(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> recv_all(socket, buffer <> data)
      {:error, :closed} -> {:ok, buffer}
      other -> other
    end
  end
end
