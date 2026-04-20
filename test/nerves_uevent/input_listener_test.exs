# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesUEvent.InputListenerTest do
  use ExUnit.Case, async: false

  alias NervesUEvent.InputListener

  @fixture_root Path.expand("../fixtures/input_id", __DIR__)

  @moduletag :tmp_dir

  setup ctx do
    _ = start_supervised!({PropertyTable, name: NervesUEvent})
    udev_data_dir = Path.join(ctx.tmp_dir, "data")
    File.mkdir!(udev_data_dir)

    %{udev_data_dir: udev_data_dir}
  end

  describe "supported?/1" do
    test "true when udev_dir is writable and manage_udev is true", ctx do
      assert InputListener.supported?(udev_dir: ctx.tmp_dir, manage_udev: true)
    end

    test "false when manage_udev is explicitly false", ctx do
      refute InputListener.supported?(udev_dir: ctx.tmp_dir, manage_udev: false)
    end

    test "creates missing data subdirectory under udev_dir", ctx do
      File.rmdir!(ctx.udev_data_dir)
      assert InputListener.supported?(udev_dir: ctx.tmp_dir, manage_udev: true)
      assert File.dir?(ctx.udev_data_dir)
    end

    test "false when udev_dir points at a file, not a directory", ctx do
      # Replace data/ with a regular file to force the stat branch to fail.
      File.rmdir!(ctx.udev_data_dir)
      File.write!(ctx.udev_data_dir, "not a dir")
      refute InputListener.supported?(udev_dir: ctx.tmp_dir, manage_udev: true)
    end
  end

  describe "initial sync" do
    test "writes udev data files for input char devices already in the table", ctx do
      parent = ["devices", "platform", "soc", "usb", "input", "input5"]
      PropertyTable.put(NervesUEvent, parent, input_kvmap("dell-usb-mouse"))

      child = parent ++ ["event5"]
      PropertyTable.put(NervesUEvent, child, char_dev("input", "13", "64"))

      start_listener!(ctx)

      path = Path.join(ctx.tmp_dir, "data/c13:64")
      contents = File.read!(path)
      assert contents =~ "E:ID_INPUT=1\n"
      assert contents =~ "E:ID_INPUT_MOUSE=1\n"
    end

    test "wipes leftover files from a previous run", ctx do
      stale = Path.join(ctx.udev_data_dir, "c13:99")
      File.write!(stale, "stale\n")

      start_listener!(ctx)

      refute File.exists?(stale)
    end

    test "ignores logical inputN nodes (no major/minor) during replay", ctx do
      PropertyTable.put(
        NervesUEvent,
        ["devices", "platform", "input", "input8"],
        input_kvmap("sigmachip-usb-keyboard")
      )

      start_listener!(ctx)

      assert File.ls!(ctx.udev_data_dir) == []
    end
  end

  describe "handle_info events" do
    test "creates a udev data file when a char device is added", ctx do
      pid = start_listener!(ctx)

      parent = ["devices", "platform", "input", "input7"]
      PropertyTable.put(NervesUEvent, parent, input_kvmap("sigmachip-usb-keyboard"))

      child = parent ++ ["event7"]
      PropertyTable.put(NervesUEvent, child, char_dev("input", "13", "65"))

      sync(pid)

      contents = File.read!(Path.join(ctx.udev_data_dir, "c13:65"))
      assert contents =~ "E:ID_INPUT=1\n"
      assert contents =~ "E:ID_INPUT_KEY=1\n"
      assert contents =~ "E:ID_INPUT_KEYBOARD=1\n"
    end

    test "classifies a touchscreen, joystick, and switch from fixtures", ctx do
      pid = start_listener!(ctx)

      cases = [
        {"byqdtech-touchscreen", "13", "70", "E:ID_INPUT_TOUCHSCREEN=1\n"},
        {"xbox-360-pad", "13", "71", "E:ID_INPUT_JOYSTICK=1\n"},
        {"vc4-hdmi-jack", "13", "72", "E:ID_INPUT_SWITCH=1\n"}
      ]

      for {{fixture, major, minor, _needle}, idx} <- Enum.with_index(cases) do
        parent = ["devices", "test", "input", "input#{idx}"]
        PropertyTable.put(NervesUEvent, parent, input_kvmap(fixture))

        PropertyTable.put(
          NervesUEvent,
          parent ++ ["event#{idx}"],
          char_dev("input", major, minor)
        )
      end

      sync(pid)

      for {_fixture, major, minor, needle} <- cases do
        contents = File.read!(Path.join(ctx.udev_data_dir, "c#{major}:#{minor}"))
        assert contents =~ "E:ID_INPUT=1\n"
        assert contents =~ needle
      end
    end

    test "removes the udev data file when the char device goes away", ctx do
      pid = start_listener!(ctx)

      parent = ["devices", "pci", "input", "input3"]
      PropertyTable.put(NervesUEvent, parent, input_kvmap("xbox-360-pad"))

      child = parent ++ ["js0"]
      PropertyTable.put(NervesUEvent, child, char_dev("input", "13", "70"))
      sync(pid)

      path = Path.join(ctx.udev_data_dir, "c13:70")
      assert File.exists?(path)

      PropertyTable.delete(NervesUEvent, child)
      sync(pid)

      refute File.exists?(path)
    end

    test "ignores devices in other subsystems", ctx do
      pid = start_listener!(ctx)

      PropertyTable.put(
        NervesUEvent,
        ["devices", "pci", "net", "eth0"],
        %{"subsystem" => "net", "major" => "1", "minor" => "2"}
      )

      sync(pid)

      assert File.ls!(ctx.udev_data_dir) == []
    end

    test "ignores the logical inputN parent (no major/minor)", ctx do
      pid = start_listener!(ctx)

      PropertyTable.put(
        NervesUEvent,
        ["devices", "platform", "input", "input9"],
        input_kvmap("dell-usb-mouse")
      )

      sync(pid)

      assert File.ls!(ctx.udev_data_dir) == []
    end

    test "writes only E:ID_INPUT=1 when classification is empty", ctx do
      pid = start_listener!(ctx)

      parent = ["devices", "platform", "input", "input10"]
      # No capability bits — InputId.classify/1 returns []
      PropertyTable.put(NervesUEvent, parent, %{"subsystem" => "input"})
      PropertyTable.put(NervesUEvent, parent ++ ["event10"], char_dev("input", "13", "80"))
      sync(pid)

      contents = File.read!(Path.join(ctx.udev_data_dir, "c13:80"))
      assert contents == "E:ID_INPUT=1\n"
    end
  end

  describe "input_rules" do
    test "appends E:KEY=VALUE for rules whose match equals the input kvmap", ctx do
      rules = [
        {%{"name" => "Dell Dell USB Optical Mouse"},
         env: %{"LIBINPUT_CALIBRATION_MATRIX" => "0 1 0 -1 0 1"}}
      ]

      pid = start_listener!(ctx, input_rules: rules)

      parent = ["devices", "platform", "input", "input11"]
      PropertyTable.put(NervesUEvent, parent, input_kvmap("dell-usb-mouse"))
      PropertyTable.put(NervesUEvent, parent ++ ["event11"], char_dev("input", "13", "81"))
      sync(pid)

      contents = File.read!(Path.join(ctx.udev_data_dir, "c13:81"))
      assert contents =~ "E:ID_INPUT_MOUSE=1\n"
      assert contents =~ "E:LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1\n"
    end

    test "requires all match keys to equal kvmap values", ctx do
      rules = [
        {%{"name" => "Dell Dell USB Optical Mouse", "phys" => "does-not-match"},
         env: %{"FOO" => "bar"}}
      ]

      pid = start_listener!(ctx, input_rules: rules)

      parent = ["devices", "platform", "input", "input12"]
      PropertyTable.put(NervesUEvent, parent, input_kvmap("dell-usb-mouse"))
      PropertyTable.put(NervesUEvent, parent ++ ["event12"], char_dev("input", "13", "82"))
      sync(pid)

      refute File.read!(Path.join(ctx.udev_data_dir, "c13:82")) =~ "FOO"
    end

    test "merges env from multiple matching rules, later rules win on conflict", ctx do
      rules = [
        {%{"name" => "Dell Dell USB Optical Mouse"}, env: %{"A" => "1", "B" => "first"}},
        {%{"name" => "Dell Dell USB Optical Mouse"}, env: %{"B" => "second", "C" => "3"}}
      ]

      pid = start_listener!(ctx, input_rules: rules)

      parent = ["devices", "platform", "input", "input13"]
      PropertyTable.put(NervesUEvent, parent, input_kvmap("dell-usb-mouse"))
      PropertyTable.put(NervesUEvent, parent ++ ["event13"], char_dev("input", "13", "83"))
      sync(pid)

      contents = File.read!(Path.join(ctx.udev_data_dir, "c13:83"))
      assert contents =~ "E:A=1\n"
      assert contents =~ "E:B=second\n"
      assert contents =~ "E:C=3\n"
    end

    test "applies rules during initial sync replay", ctx do
      rules = [{%{"name" => "Microsoft X-Box 360 pad"}, env: %{"JOYSTICK_QUIRK" => "yes"}}]

      parent = ["devices", "pci", "input", "input14"]
      PropertyTable.put(NervesUEvent, parent, input_kvmap("xbox-360-pad"))
      PropertyTable.put(NervesUEvent, parent ++ ["js0"], char_dev("input", "13", "84"))

      _ = start_listener!(ctx, input_rules: rules)

      contents = File.read!(Path.join(ctx.udev_data_dir, "c13:84"))
      assert contents =~ "E:JOYSTICK_QUIRK=yes\n"
    end

    test "rules with no :env action are a no-op but still valid", ctx do
      rules = [{%{"name" => "Dell Dell USB Optical Mouse"}, []}]
      pid = start_listener!(ctx, input_rules: rules)

      parent = ["devices", "platform", "input", "input15"]
      PropertyTable.put(NervesUEvent, parent, input_kvmap("dell-usb-mouse"))
      PropertyTable.put(NervesUEvent, parent ++ ["event15"], char_dev("input", "13", "85"))
      sync(pid)

      contents = File.read!(Path.join(ctx.udev_data_dir, "c13:85"))
      assert contents =~ "E:ID_INPUT_MOUSE=1\n"
    end
  end

  defp start_listener!(ctx, extra_opts \\ []) do
    opts = Keyword.merge([udev_dir: ctx.tmp_dir], extra_opts)
    pid = start_supervised!({InputListener, opts})
    sync(pid)
    pid
  end

  # Synchronous round-trip against the listener's mailbox. Because Erlang
  # mailboxes are FIFO and PropertyTable.put/delete are synchronous calls
  # that send subscriber notifications before returning, waiting on
  # :sys.get_state guarantees every prior notification has been handled.
  defp sync(pid) do
    _ = :sys.get_state(pid)
    :ok
  end

  defp char_dev(subsystem, major, minor) do
    %{"subsystem" => subsystem, "major" => major, "minor" => minor}
  end

  # Load a sysfs uevent fixture into the kvmap shape InputListener expects
  # for the inputN parent: lowercase keys, unquoted values, with
  # subsystem=input tacked on (real sysfs provides this separately).
  defp input_kvmap(fixture) do
    @fixture_root
    |> Path.join(fixture <> ".uevent")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {String.downcase(k), String.trim(v, "\"")}
    end)
    |> Map.put("subsystem", "input")
  end
end
