# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesUEvent.InputId do
  @moduledoc false
  # Classify an input device from its sysfs inputN directory. Ported from
  # systemd's udev-builtin-input_id.c so that libinput recognizes the same
  # device types it would on a udev-based system.

  import Bitwise

  # linux/input-event-codes.h — only the codes the classifier looks at.
  @ev_key 0x01
  @ev_rel 0x02
  @ev_abs 0x03
  @ev_sw 0x05

  @key_esc 1
  @key_q 16
  @btn_misc 0x100
  @btn_1 0x101
  @btn_left 0x110
  @btn_trigger 0x120
  @btn_a 0x130
  @btn_tool_pen 0x140
  @btn_tool_finger 0x145
  @btn_touch 0x14A
  @btn_stylus 0x14B

  @abs_x 0x00
  @abs_y 0x01
  @abs_z 0x02
  @abs_rx 0x03
  @abs_ry 0x04
  @abs_rz 0x05
  @abs_throttle 0x06
  @abs_rudder 0x07
  @abs_wheel 0x08
  @abs_gas 0x09
  @abs_brake 0x0A
  @abs_mt_position_x 0x35
  @abs_mt_position_y 0x36

  @rel_x 0x00
  @rel_y 0x01

  @prop_direct 0x01
  @prop_semi_mt 0x03
  @prop_pointing_stick 0x05
  @prop_accelerometer 0x06

  @type class ::
          :key
          | :keyboard
          | :mouse
          | :touchpad
          | :touchscreen
          | :joystick
          | :tablet
          | :accelerometer
          | :pointingstick
          | :switch

  @doc """
  Classify an input device from its inputN uevent kvmap.

  The kvmap is the `value` stored in `PropertyTable` for the logical input
  node — e.g. `%{"ev" => "20000b", "key" => "...", ...}`. The kernel emits
  the same space-separated hex words in uevents that sysfs exposes under
  `capabilities/`, so no sysfs reads are needed. Returns a list of class
  atoms matching the `ID_INPUT_*` properties udev's `input_id` builtin sets.
  """
  @spec classify(map()) :: [class()]
  def classify(input_kvmap) do
    ev = parse_bitmap(Map.get(input_kvmap, "ev", ""))
    key = parse_bitmap(Map.get(input_kvmap, "key", ""))
    abs_ = parse_bitmap(Map.get(input_kvmap, "abs", ""))
    rel = parse_bitmap(Map.get(input_kvmap, "rel", ""))
    prop = parse_bitmap(Map.get(input_kvmap, "prop", ""))

    has_keys = bit?(ev, @ev_key)
    has_abs_xy = bit?(ev, @ev_abs) and bit?(abs_, @abs_x) and bit?(abs_, @abs_y)
    has_3d = has_abs_xy and bit?(abs_, @abs_z)

    accelerometer? = bit?(prop, @prop_accelerometer) or (not has_keys and has_3d)

    pointer =
      if accelerometer?,
        do: [:accelerometer],
        else: pointer_classes(ev, key, abs_, rel, prop, has_abs_xy)

    pointer ++ switch_class(ev) ++ key_classes(has_keys, key)
  end

  defp switch_class(ev), do: if(bit?(ev, @ev_sw), do: [:switch], else: [])

  defp key_classes(false, _key), do: []

  defp key_classes(true, key) do
    any_key? = Enum.any?(@key_esc..(@btn_misc - 1), &bit?(key, &1))

    cond do
      any_key? and bit?(key, @key_q) -> [:key, :keyboard]
      any_key? -> [:key]
      true -> []
    end
  end

  defp pointer_classes(ev, key, abs_, rel, prop, has_abs_xy) do
    pointing_stick? = bit?(prop, @prop_pointing_stick)
    stylus? = bit?(key, @btn_stylus)
    pen? = bit?(key, @btn_tool_pen)
    finger_but_no_pen? = bit?(key, @btn_tool_finger) and not pen?
    mouse_button? = bit?(key, @btn_left)
    touch? = bit?(key, @btn_touch)
    direct? = bit?(prop, @prop_direct)
    rel_xy? = bit?(ev, @ev_rel) and bit?(rel, @rel_x) and bit?(rel, @rel_y)

    mt_xy? =
      bit?(abs_, @abs_mt_position_x) and bit?(abs_, @abs_mt_position_y) and
        not bit?(prop, @prop_semi_mt)

    initial = %{mouse: false, touchpad: false, touchscreen: false, joystick: false, tablet: false}

    r =
      initial
      |> from_abs(has_abs_xy, stylus?, pen?, finger_but_no_pen?, mouse_button?, touch?, direct?, key, abs_)
      |> from_mt(mt_xy?, stylus?, pen?, finger_but_no_pen?, touch?, direct?)

    mouse? = r.mouse or (rel_xy? and mouse_button?)

    []
    |> prepend_if(pointing_stick?, :pointingstick)
    |> prepend_if(mouse? or pointing_stick?, :mouse)
    |> prepend_if(r.touchpad, :touchpad)
    |> prepend_if(r.touchscreen, :touchscreen)
    |> prepend_if(r.joystick, :joystick)
    |> prepend_if(r.tablet, :tablet)
  end

  defp from_abs(r, false, _, _, _, _, _, _, _, _), do: r

  defp from_abs(r, true, stylus?, pen?, finger_but_no_pen?, mouse_button?, touch?, direct?, key, abs_) do
    cond do
      stylus? or pen? ->
        %{r | tablet: true}

      finger_but_no_pen? and not direct? ->
        %{r | touchpad: true}

      mouse_button? ->
        %{r | mouse: true}

      touch? or direct? ->
        %{r | touchscreen: true}

      true ->
        %{r | joystick: joystick_axes?(key, abs_)}
    end
  end

  defp joystick_axes?(key, abs_) do
    bit?(key, @btn_trigger) or bit?(key, @btn_a) or bit?(key, @btn_1) or
      bit?(abs_, @abs_rx) or bit?(abs_, @abs_ry) or bit?(abs_, @abs_rz) or
      bit?(abs_, @abs_throttle) or bit?(abs_, @abs_rudder) or
      bit?(abs_, @abs_wheel) or bit?(abs_, @abs_gas) or bit?(abs_, @abs_brake)
  end

  defp from_mt(r, false, _, _, _, _, _), do: r

  defp from_mt(r, true, stylus?, pen?, finger_but_no_pen?, touch?, direct?) do
    cond do
      stylus? or pen? -> %{r | tablet: true}
      finger_but_no_pen? and not direct? -> %{r | touchpad: true}
      touch? or direct? -> %{r | touchscreen: true}
      true -> r
    end
  end

  defp prepend_if(list, true, atom), do: [atom | list]
  defp prepend_if(list, false, _), do: list

  defp bit?(bitmap, bit), do: band(bitmap, bsl(1, bit)) != 0

  # Kernel bitmap format (uevent or sysfs): space-separated hex words,
  # most-significant word first. Word size is the kernel's
  # `sizeof(unsigned long)`, which matches the running BEAM's wordsize on
  # Nerves (native kernel, native BEAM). Absent capability strings are
  # treated as all-zero.
  defp parse_bitmap(str) when str in ["", nil], do: 0

  defp parse_bitmap(str) do
    word_bits = :erlang.system_info(:wordsize) * 8

    str
    |> String.split([" ", "\t", "\n", "\r"], trim: true)
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {hex, i}, acc ->
      bor(acc, bsl(String.to_integer(hex, 16), i * word_bits))
    end)
  end
end
