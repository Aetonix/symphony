defmodule SymphonyElixir.JSON do
  @moduledoc false

  require Logger

  @replacement "\uFFFD"

  @spec encode!(term(), keyword()) :: String.t()
  def encode!(value, opts \\ []) do
    value
    |> sanitize()
    |> Jason.encode!(opts)
  end

  @spec sanitize(term()) :: term()
  def sanitize(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      Logger.warning("Sanitized invalid UTF-8 bytes before JSON encoding")
      String.replace_invalid(value, @replacement)
    end
  end

  def sanitize(values) when is_list(values), do: Enum.map(values, &sanitize/1)

  def sanitize(values) when is_map(values) do
    for {key, value} <- values, into: %{} do
      {sanitize_key(key), sanitize(value)}
    end
  end

  def sanitize(value), do: value

  defp sanitize_key(key) when is_binary(key), do: sanitize(key)
  defp sanitize_key(key), do: key
end
