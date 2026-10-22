defmodule SymphonyElixir.Agent.AcpClient do
  @moduledoc """
  ACP client shared by every agent implementer.

  Symphony speaks `session/new` and `session/prompt`. Tracker tools run in this
  BEAM and their credentials are not placed in the agent environment.
  """

  require Logger

  alias SymphonyElixir.{Agent.Registry, Agent.ToolBroker, Codex.DynamicTool, JSON, PathSafety, SSH}

  @protocol_version 1
  @prompt_timeout_ms 3_600_000
  @port_line_bytes 1_048_576

  @type session :: %{
          port: port(),
          session_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          agent: map(),
          metadata: map()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    Process.put(:symphony_acp_request_id, 0)
    worker_host = Keyword.get(opts, :worker_host)
    issue = Keyword.get(opts, :issue, %{labels: []})

    with {:ok, agent} <- Registry.resolve(SymphonyElixir.Config.settings!(), issue),
         {:ok, workspace} <- validate_workspace(workspace, worker_host),
         {:ok, binding, mcp_servers} <- tool_servers(),
         {:ok, port} <- open_port(workspace, worker_host, agent.command, binding) do
      metadata = port_metadata(port, worker_host)

      with {:ok, init} <- request(port, "initialize", initialize_params(), @prompt_timeout_ms),
           :ok <- require_http_mcp(init),
           :ok <- maybe_authenticate(port, agent.implementer, init),
           {:ok, created} <- request(port, "session/new", %{"cwd" => workspace, "mcpServers" => mcp_servers}, @prompt_timeout_ms),
           {:ok, session_id} <- session_id(created) do
        {:ok,
         %{
           port: port,
           session_id: session_id,
           workspace: workspace,
           worker_host: worker_host,
           agent: agent,
           metadata: metadata
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_prompt(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_prompt(session, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)
    prompt_number = Keyword.get(opts, :prompt_number, 1)
    prompt_id = "#{session.session_id}-#{prompt_number}"

    emit(on_message, :prompt_started, %{session_id: prompt_id, text: "Prompt #{prompt_number}"}, session.metadata)

    params = %{
      "sessionId" => session.session_id,
      "prompt" => [%{"type" => "text", "text" => prompt}]
    }

    case request(session.port, "session/prompt", params, @prompt_timeout_ms, on_message, session) do
      {:ok, %{"stopReason" => reason} = result} when reason in ["cancelled", "error"] ->
        {:error, {:prompt_failed, result}}

      {:ok, result} ->
        emit(on_message, :prompt_completed, %{session_id: prompt_id, text: "Prompt completed"}, session.metadata)
        {:ok, %{result: result, session_id: prompt_id}}

      {:error, reason} ->
        emit(on_message, :prompt_failed, %{session_id: prompt_id, text: inspect(reason)}, session.metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) do
    stop_port(port)
  end

  defp initialize_params do
    %{
      "protocolVersion" => @protocol_version,
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      },
      "clientInfo" => %{
        "name" => "symphony",
        "title" => "Symphony",
        "version" => "0.0.3"
      }
    }
  end

  defp maybe_authenticate(port, implementer, init) do
    method_id = implementer.auth_method_id()
    methods = Map.get(init, "authMethods") || []

    if Enum.any?(methods, &(is_map(&1) and &1["id"] == method_id)) do
      case request(port, "authenticate", %{"methodId" => method_id}, @prompt_timeout_ms) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp session_id(%{"sessionId" => session_id}) when is_binary(session_id), do: {:ok, session_id}
  defp session_id(result), do: {:error, {:invalid_session, result}}

  defp require_http_mcp(%{"agentCapabilities" => %{"mcpCapabilities" => %{"http" => true}}}), do: :ok
  defp require_http_mcp(_init), do: {:error, :agent_http_mcp_required}

  defp tool_servers do
    binding =
      try do
        DynamicTool.bind()
      rescue
        _error -> %{tool_specs: [], secret_environment_names: []}
      end

    with :ok <- ToolBroker.ensure_started(),
         {:ok, token, port} <- ToolBroker.register(binding) do
      {:ok, binding, [http_mcp_server(port, token)]}
    end
  end

  defp http_mcp_server(port, token) do
    %{
      "type" => "http",
      "name" => "symphony",
      "url" => "http://127.0.0.1:#{port}/mcp",
      "headers" => [
        %{"name" => "Authorization", "value" => "Bearer " <> token}
      ]
    }
  end

  defp open_port(workspace, nil, command, binding) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      bash ->
        port =
          Port.open({:spawn_executable, String.to_charlist(bash)}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(launch_command(command, binding))],
            cd: String.to_charlist(workspace),
            env: secret_env(binding),
            line: @port_line_bytes
          ])

        {:ok, port}
    end
  end

  defp open_port(workspace, worker_host, command, binding) when is_binary(worker_host) do
    remote = ["cd #{shell_escape(workspace)}", launch_command(command, binding)] |> Enum.join(" && ")
    SSH.start_port(worker_host, remote, line: @port_line_bytes)
  end

  defp launch_command(command, binding) do
    [unset_command(binding), "exec #{command}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp unset_command(%{secret_environment_names: names}) do
    case Enum.filter(names, &(is_binary(&1) and String.match?(&1, ~r/^[A-Za-z_][A-Za-z0-9_]*$/))) do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp unset_command(_binding), do: nil

  defp secret_env(%{secret_environment_names: names}) do
    names
    |> Enum.filter(&(is_binary(&1) and String.match?(&1, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)))
    |> Enum.map(&{String.to_charlist(&1), false})
  end

  defp secret_env(_binding), do: []

  defp request(port, method, params, timeout_ms, on_message \\ nil, session \\ nil) do
    id = next_id()

    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })

    await(port, id, timeout_ms, "", on_message, session)
  end

  defp await(port, id, timeout_ms, pending, on_message, session) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_line(port, id, timeout_ms, pending <> to_string(chunk), on_message, session)

      {^port, {:data, {:noeol, chunk}}} ->
        await(port, id, timeout_ms, pending <> to_string(chunk), on_message, session)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :prompt_timeout}
    end
  end

  defp handle_line(port, id, timeout_ms, line, on_message, session) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, {:acp_error, error}}

      {:ok, %{"method" => method, "id" => request_id} = message} when not is_nil(request_id) ->
        respond_to_agent(port, method, request_id, message, on_message, session)
        await(port, id, timeout_ms, "", on_message, session)

      {:ok, %{"method" => "session/update", "params" => params}} ->
        emit_update(on_message, params, session)
        await(port, id, timeout_ms, "", on_message, session)

      {:ok, %{"method" => method} = message} ->
        emit(on_message, :notification, %{text: to_string(method), raw: message}, metadata(session))
        await(port, id, timeout_ms, "", on_message, session)

      {:ok, other} ->
        emit(on_message, :notification, %{text: "message", raw: other}, metadata(session))
        await(port, id, timeout_ms, "", on_message, session)

      {:error, _reason} ->
        await(port, id, timeout_ms, "", on_message, session)
    end
  end

  defp respond_to_agent(port, "session/request_permission", request_id, message, on_message, session) do
    option_id =
      message
      |> get_in(["params", "options"])
      |> List.wrap()
      |> Enum.find_value("allow-once", fn option -> option["optionId"] || option["id"] end)

    tool = get_in(message, ["params", "toolCall", "title"]) || "permission"
    emit(on_message, :permission, %{kind: "tool", text: "Allowed #{tool}", raw: message}, metadata(session))

    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
    })
  end

  defp respond_to_agent(port, method, request_id, _message, _on_message, _session) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => %{"code" => -32_601, "message" => "Symphony does not implement #{method}"}
    })
  end

  defp emit_update(on_message, params, session) do
    update = Map.get(params, "update") || %{}
    rendered = render_update(update)

    emit(
      on_message,
      :session_update,
      Map.merge(rendered, %{raw: update, session_id: session && session.session_id}),
      metadata(session)
    )
  end

  defp render_update(%{"sessionUpdate" => "agent_message_chunk"} = update) do
    %{kind: "message", text: content_text(update["content"])}
  end

  defp render_update(%{"sessionUpdate" => "agent_thought_chunk"} = update) do
    %{kind: "thought", text: content_text(update["content"])}
  end

  defp render_update(%{"sessionUpdate" => "tool_call"} = update) do
    %{kind: "tool", text: to_string(update["title"] || update["toolCallId"] || "tool")}
  end

  defp render_update(%{"sessionUpdate" => "tool_call_update"} = update) do
    %{kind: "tool", text: to_string(update["title"] || update["status"] || "tool update")}
  end

  defp render_update(%{"sessionUpdate" => kind}) do
    %{kind: "status", text: to_string(kind)}
  end

  defp render_update(_update), do: %{kind: "status", text: "update"}

  defp content_text(%{"text" => text}) when is_binary(text), do: text
  defp content_text(text) when is_binary(text), do: text
  defp content_text(_content), do: ""

  defp emit(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp emit(_on_message, _event, _details, _metadata), do: :ok

  defp metadata(%{metadata: metadata}), do: metadata
  defp metadata(_session), do: %{}

  defp next_id do
    id = Process.get(:symphony_acp_request_id, 0) + 1
    Process.put(:symphony_acp_request_id, id)
    id
  end

  defp send_message(port, message) do
    Port.command(port, JSON.encode!(message) <> "\n")
  end

  defp stop_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp port_metadata(port, worker_host) do
    base =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{agent_pid: to_string(os_pid)}
        _ -> %{}
      end

    if is_binary(worker_host), do: Map.put(base, :worker_host, worker_host), else: base
  end

  defp validate_workspace(workspace, nil) do
    expanded = Path.expand(workspace)

    case PathSafety.canonicalize(expanded) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_workspace(workspace, worker_host) when is_binary(worker_host) do
    if String.trim(workspace) == "" do
      {:error, {:invalid_workspace_cwd, worker_host}}
    else
      {:ok, workspace}
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
