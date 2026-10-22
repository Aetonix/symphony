defmodule SymphonyElixir.SkillsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Skills

  test "installs the bundled skills and removes stale entries" do
    root = Path.join(System.tmp_dir!(), "symphony-skills-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    stale = Path.join(root, "retired/SKILL.md")
    File.mkdir_p!(Path.dirname(stale))
    File.write!(stale, "gone")

    assert {:ok, ^root} = Skills.install(root)

    manifest = Skills.manifest()

    Enum.each(manifest, fn {relative, contents, mode} ->
      target = Path.join(root, relative)
      assert File.read!(target) == contents
      assert Bitwise.band(File.stat!(target).mode, 0o777) == Bitwise.band(mode, 0o777)
    end)

    watcher = Path.join(root, "land/land_watch.py")
    assert Bitwise.band(File.stat!(watcher).mode, 0o111) != 0

    refute File.exists?(stale)
  end

  test "installs into the default home location when no root is configured" do
    previous_root = Application.get_env(:symphony_elixir, :skills_root)
    Application.delete_env(:symphony_elixir, :skills_root)
    on_exit(fn -> restore_env(:skills_root, previous_root) end)

    home = Path.join(System.tmp_dir!(), "symphony-home-#{System.unique_integer([:positive])}")
    expected = Path.join(home, ".agents/skills/symphony")
    on_exit(fn -> File.rm_rf(home) end)

    assert expected == Skills.default_root(fn -> home end)
  end

  test "reports a failure to clear the install root" do
    root = Path.join(System.tmp_dir!(), "symphony-skills-#{System.unique_integer([:positive])}")

    assert {:error, :eacces} = Skills.install(root, failing_fs(rm_rf: {:error, :eacces, root}))
  end

  test "reports a failure to write a skill file" do
    root = Path.join(System.tmp_dir!(), "symphony-skills-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, :enospc} = Skills.install(root, failing_fs(write: {:error, :enospc}))
    refute File.exists?(Path.join(root, "commit/SKILL.md"))
  end

  test "installs into the configured skills root by default" do
    root = Path.join(System.tmp_dir!(), "symphony-skills-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    previous = Application.get_env(:symphony_elixir, :skills_root)
    Application.put_env(:symphony_elixir, :skills_root, root)
    on_exit(fn -> restore_env(:skills_root, previous) end)

    assert {:ok, ^root} = Skills.install()
    assert File.regular?(Path.join(root, "commit/SKILL.md"))
  end

  defp failing_fs(overrides) do
    %{
      rm_rf: fn path -> Keyword.get(overrides, :rm_rf, File.rm_rf(path)) end,
      write: fn path, contents -> Keyword.get(overrides, :write, File.write(path, contents)) end,
      chmod: fn path, mode -> Keyword.get(overrides, :chmod, File.chmod(path, mode)) end
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
