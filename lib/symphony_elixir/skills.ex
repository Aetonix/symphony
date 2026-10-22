defmodule SymphonyElixir.Skills do
  @moduledoc """
  Installs the agent skills bundled with Symphony.

  The skills live in `priv/skills` and are embedded at compile time, so the
  install works from source, the escript, and a Burrito release. Symphony
  installs them into `~/.agents/skills/symphony` on startup, which is where
  agents discover user-level skills.
  """

  @skills_root Path.expand("priv/skills", File.cwd!())
  @manifest_stamp Path.join(@skills_root, ".manifest")

  # Touched whenever the skill set changes so Mix recompiles this module and
  # rebuilds the embedded manifest below.
  newest_mtime =
    @skills_root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&(File.regular?(&1) and Path.basename(&1) != ".manifest"))
    |> Enum.map(&File.stat!(&1).mtime)
    |> Enum.max()

  File.touch!(@manifest_stamp, newest_mtime)
  @external_resource @manifest_stamp

  @manifest @skills_root
            |> Path.join("**/*")
            |> Path.wildcard(match_dot: true)
            |> Enum.filter(&(File.regular?(&1) and Path.basename(&1) != ".manifest"))
            |> Enum.sort()
            |> Enum.map(fn path ->
              relative = Path.relative_to(path, @skills_root)
              mode = path |> File.stat!() |> Map.fetch!(:mode)
              {relative, File.read!(path), mode}
            end)

  @doc """
  Writes the bundled skills under `root`, replacing anything already there.

  `root` defaults to `~/.agents/skills/symphony`. Returns `{:ok, root}`.
  """
  @spec install(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def install(root \\ default_root()) do
    install(root, %{rm_rf: &File.rm_rf/1, write: &File.write/2, chmod: &File.chmod/2})
  end

  @doc false
  @spec install(Path.t(), map()) :: {:ok, Path.t()} | {:error, term()}
  def install(root, %{rm_rf: rm_rf, write: write, chmod: chmod}) do
    root = Path.expand(root)

    with :ok <- remove_existing(root, rm_rf),
         :ok <- write_manifest(root, write, chmod) do
      {:ok, root}
    end
  end

  @doc """
  Returns the bundled skills as `{relative_path, contents, mode}` tuples.
  """
  @spec manifest() :: [{Path.t(), binary(), non_neg_integer()}]
  def manifest, do: @manifest

  @doc false
  @spec default_root((-> Path.t())) :: Path.t()
  def default_root(user_home \\ &System.user_home!/0) do
    case Application.get_env(:symphony_elixir, :skills_root) do
      root when is_binary(root) and root != "" -> root
      _ -> Path.join(user_home.(), ".agents/skills/symphony")
    end
  end

  defp remove_existing(root, rm_rf) do
    case rm_rf.(root) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp write_manifest(root, write, chmod) do
    Enum.reduce_while(@manifest, :ok, fn {relative, contents, mode}, :ok ->
      target = Path.join(root, relative)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- write.(target, contents),
           :ok <- chmod.(target, mode) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
