# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesUEvent.InputIdTest do
  use ExUnit.Case, async: true

  alias NervesUEvent.InputId

  @fixture_root Path.expand("../fixtures/input_id", __DIR__)

  describe "classify/1" do
    test "touchscreen with BTN_TOUCH and ABS_X/Y but no PROP_DIRECT" do
      assert classify_fixture("byqdtech-touchscreen") == [:touchscreen]
    end

    test "relative-axis mouse with BTN_LEFT" do
      assert classify_fixture("dell-usb-mouse") == [:mouse]
    end

    test "switch-only device (HDMI jack)" do
      assert classify_fixture("vc4-hdmi-jack") == [:switch]
    end

    test "keyboard with KEY_ESC and KEY_Q" do
      assert classify_fixture("sigmachip-usb-keyboard") == [:key, :keyboard]
    end

    test "gamepad with BTN_A and analog axes" do
      assert classify_fixture("xbox-360-pad") == [:joystick]
    end

    test "empty kvmap classifies as nothing" do
      assert InputId.classify(%{}) == []
    end

    test "accelerometer via PROP_ACCELEROMETER bit" do
      # PROP bit 6 set → accelerometer regardless of other bits
      assert InputId.classify(%{"prop" => "40"}) == [:accelerometer]
    end

    test "accelerometer via 3-axis absolute with no keys" do
      # EV_ABS set, ABS_X/Y/Z set, EV_KEY not set → accelerometer
      assert InputId.classify(%{"ev" => "8", "abs" => "7"}) == [:accelerometer]
    end

    test "pointingstick via PROP_POINTING_STICK" do
      # EV_KEY + EV_REL, BTN_LEFT, REL_X/Y, PROP_POINTING_STICK (bit 5)
      kvmap = %{
        "ev" => "7",
        "key" => "10000 0 0 0 0",
        "rel" => "3",
        "prop" => "20"
      }

      assert InputId.classify(kvmap) == [:mouse, :pointingstick]
    end

    test "touchpad via BTN_TOOL_FINGER without pen and no PROP_DIRECT" do
      # KEY bit 0x145 (BTN_TOOL_FINGER, word 5 / bit 5) set, ABS_X/Y set
      kvmap = %{
        "ev" => "b",
        "key" => "20 0 0 0 0 0",
        "abs" => "3"
      }

      assert InputId.classify(kvmap) == [:touchpad]
    end

    test "tablet via BTN_STYLUS" do
      # KEY bit 0x14B (BTN_STYLUS, word 5 / bit 11) set with ABS_X/Y
      kvmap = %{
        "ev" => "b",
        "key" => "800 0 0 0 0 0",
        "abs" => "3"
      }

      assert InputId.classify(kvmap) == [:tablet]
    end

    test "multi-touch touchscreen via ABS_MT_POSITION_X/Y and PROP_DIRECT" do
      # ABS bits 0x35/0x36 set (plus ABS_X/Y), PROP_DIRECT (bit 1) set
      kvmap = %{
        "ev" => "b",
        "abs" => "60000000000003",
        "prop" => "2"
      }

      assert InputId.classify(kvmap) == [:touchscreen]
    end

    test "keys but no keyboard (no KEY_Q)" do
      # KEY_ESC (bit 1) set, KEY_Q (bit 16) not set
      kvmap = %{"ev" => "3", "key" => "2"}
      assert InputId.classify(kvmap) == [:key]
    end

    test "absent bitmap strings are treated as zero" do
      # EV_KEY alone — no KEY= at all
      assert InputId.classify(%{"ev" => "2"}) == []
    end
  end

  defp classify_fixture(name) do
    @fixture_root
    |> Path.join(name <> ".uevent")
    |> parse_uevent()
    |> InputId.classify()
  end

  # Parse a sysfs-style uevent file into the same shape `InputId.classify/1`
  # receives from PropertyTable: lowercase keys, unquoted values.
  defp parse_uevent(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {String.downcase(k), String.trim(v, "\"")}
    end)
  end
end
