defmodule SymphonyElixir.Agent.ToolBroker do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.{Codex.DynamicTool, JSON}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec register(map()) :: {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def register(binding) when is_map(binding) do
    GenServer.call(__MODULE__, {:register, binding})
  end

  @impl true
  def init(_opts) do
    case :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}]) do
      {:ok, listen} ->
        {:ok, port} = :inet.port(listen)
        parent = self()
        acceptor = spawn_link(fn -> accept_loop(listen, parent) end)
        {:ok, %{listen: listen, port: port, acceptor: acceptor, sessions: %{}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register, binding}, _from, state) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    {:reply, {:ok, token, state.port}, %{state | sessions: Map.put(state.sessions, token, binding)}}
  end

  def handle_call({:dispatch, token, message}, _from, state) do
    {:reply, dispatch(token, message, state.sessions), state}
  end

  @impl true
  def handle_info({:tcp_request, token, message, from}, state) do
    response = dispatch(token, message, state.sessions)
    send(from, {:tcp_response, response})
    {:noreply, state}
  end

  defp accept_loop(listen, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, parent) end)
        accept_loop(listen, parent)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen, parent)
    end
  end

  defp serve(socket, parent) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, line} ->
        response =
          case JSON.sanitize(line) |> Jason.decode() do
            {:ok, %{"token" => token, "message" => message}} ->
              send(parent, {:tcp_request, token, message, self()})

              receive do
                {:tcp_response, payload} -> payload
              after
                30_000 -> %{"error" => "tool broker timeout"}
              end

            _ ->
              %{"error" => "invalid tool broker request"}
          end

        :gen_tcp.send(socket, [JSON.encode!(response), ?\n])
        serve(socket, parent)

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp dispatch(token, message, sessions) do
    case Map.fetch(sessions, token) do
      {:ok, binding} -> mcp_response(message, binding)
      :error -> %{"jsonrpc" => "2.0", "id" => id_of(message), "error" => %{"code" => -32_001, "message" => "unknown tool session"}}
    end
  end

  defp mcp_response(%{"method" => "initialize"} = message, _binding) do
    %{
      "jsonrpc" => "2.0",
      "id" => id_of(message),
      "result" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "symphony", "version" => "0.0.3"}
      }
    }
  end

  defp mcp_response(%{"method" => "tools/list"} = message, binding) do
    %{
      "jsonrpc" => "2.0",
      "id" => id_of(message),
      "result" => %{"tools" => binding.tool_specs}
    }
  end

  defp mcp_response(%{"method" => "tools/call"} = message, binding) do
    name = get_in(message, ["params", "name"])
    arguments = get_in(message, ["params", "arguments"]) || %{}
    result = DynamicTool.execute(name, arguments, binding, [])
    text = result["output"] || JSON.encode!(result)

    %{
      "jsonrpc" => "2.0",
      "id" => id_of(message),
      "result" => %{
        "content" => [%{"type" => "text", "text" => text}],
        "isError" => result["success"] == false
      }
    }
  end

  defp mcp_response(message, _binding) do
    %{
      "jsonrpc" => "2.0",
      "id" => id_of(message),
      "error" => %{"code" => -32_601, "message" => "method not found"}
    }
  end

  defp id_of(%{"id" => id}), do: id
  defp id_of(_message), do: nil
end
