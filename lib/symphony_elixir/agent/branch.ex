defmodule SymphonyElixir.Agent.Branch do
  @moduledoc false

  @spec name(map()) :: String.t()
  def name(issue) when is_map(issue) do
    case value(issue, :branch_name) do
      name when is_binary(name) and name != "" -> sanitize(name)
      _ -> derived_name(issue)
    end
  end

  @spec base(map() | nil) :: String.t()
  def base(settings) do
    case settings do
      %{workspace: %{base_branch: branch}} when is_binary(branch) and branch != "" -> branch
      _ -> "main"
    end
  end

  defp derived_name(issue) do
    identifier = value(issue, :identifier)
    title = value(issue, :title) |> to_string() |> slug()

    [identifier, title]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("-")
    |> case do
      "" -> "issue"
      name -> sanitize(name)
    end
  end

  defp slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp sanitize(name) do
    name
    |> String.trim()
    |> String.trim_leading("refs/heads/")
    |> String.trim_leading("origin/")
    |> String.replace(~r/[^A-Za-z0-9._\/-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "issue"
      cleaned -> cleaned
    end
  end

  defp value(issue, key) do
    Map.get(issue, key) || Map.get(issue, to_string(key))
  end
end
