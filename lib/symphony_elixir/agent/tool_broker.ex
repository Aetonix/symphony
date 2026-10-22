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
    case :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}]) do
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

  @impl true
  def handle_info({:http_request, token, message, from}, state) do
    send(from, {:http_response, dispatch(token, message, state.sessions)})
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
    case read_request(socket) do
      {:ok, request} ->
        :gen_tcp.send(socket, answer(request, parent))
        :gen_tcp.close(socket)

      :closed ->
        :gen_tcp.close(socket)
    end
  end

  defp answer(%{method: "POST", path: "/mcp", headers: headers, body: body}, parent) do
    case JSON.sanitize(body) |> Jason.decode() do
      {:ok, message} ->
        token = bearer(headers)
        send(parent, {:http_request, token, message, self()})

        response =
          receive do
            {:http_response, payload} -> payload
          after
            30_000 -> %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_000, "message" => "tool broker timeout"}}
          end

        http_response(status_for(response), JSON.encode!(response))

      {:error, _reason} ->
        http_response(400, JSON.encode!(%{"error" => "invalid json"}))
    end
  end

  defp answer(%{method: "POST"}, _parent), do: http_response(404, JSON.encode!(%{"error" => "not found"}))
  defp answer(_request, _parent), do: http_response(405, JSON.encode!(%{"error" => "method not allowed"}))

  defp status_for(%{"error" => %{"code" => -32_001}}), do: 401
  defp status_for(_response), do: 200

  defp bearer(headers) do
    case Map.get(headers, "authorization", "") do
      "Bearer " <> token -> token
      "bearer " <> token -> token
      _ -> nil
    end
  end

  defp read_request(socket) do
    with {:ok, buffer} <- read_until(socket, "", "\r\n\r\n"),
         {:ok, request, rest} <- split_headers(buffer),
         {:ok, body} <- read_body(socket, rest, request.content_length) do
      {:ok, %{request | body: body}}
    else
      _ -> :closed
    end
  end

  defp split_headers(buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, rest] -> request_from_head(head, rest)
      _ -> :error
    end
  end

  defp request_from_head(head, rest) do
    case String.split(head, "\r\n") do
      [request_line | header_lines] -> request_from_line(request_line, header_lines, rest)
      _ -> :error
    end
  end

  defp request_from_line(request_line, header_lines, rest) do
    case String.split(request_line, " ") do
      [method, path | _] ->
        headers = header_map(header_lines)

        {:ok,
         %{
           method: method,
           path: path,
           headers: headers,
           content_length: content_length(headers),
           body: ""
         }, rest}

      _ ->
        :error
    end
  end

  defp header_map(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> Map.put(acc, String.downcase(name), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp content_length(headers) do
    case Integer.parse(Map.get(headers, "content-length", "0")) do
      {length, _} when length >= 0 -> length
      _ -> 0
    end
  end

  defp read_body(_socket, rest, length) when byte_size(rest) >= length, do: {:ok, binary_part(rest, 0, length)}

  defp read_body(socket, rest, length) do
    case :gen_tcp.recv(socket, length - byte_size(rest), 15_000) do
      {:ok, data} -> {:ok, rest <> data}
      {:error, _reason} -> :error
    end
  end

  defp read_until(socket, buffer, marker) do
    if String.contains?(buffer, marker) do
      {:ok, buffer}
    else
      case :gen_tcp.recv(socket, 0, 15_000) do
        {:ok, data} -> read_until(socket, buffer <> data, marker)
        {:error, _reason} -> :error
      end
    end
  end

  defp http_response(status, body) do
    reason = %{200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found", 405 => "Method Not Allowed"}

    [
      "HTTP/1.1 #{status} #{reason[status]}\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Connection: close\r\n",
      "\r\n",
      body
    ]
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
