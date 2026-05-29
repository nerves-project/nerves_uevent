# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

# The C port's parser/encoder (encode_uevent in c_src/uevent.c) is exercised by
# a small C harness in test/c/uevent_encode_test.c. This module compiles and
# runs that harness so it participates in `mix test`.
#
# The harness #includes uevent.c and links against libmnl and erl_interface, so
# it only builds on Linux (the same constraint as the port itself). The module
# is therefore only defined on Linux; elsewhere there's nothing to run.
if :os.type() == {:unix, :linux} do
  defmodule NervesUEvent.UEventEncodeTest do
    use ExUnit.Case, async: true

    @project_root Path.expand("../..", __DIR__)
    @c_src Path.join(@project_root, "c_src")
    @harness Path.join(@project_root, "test/c/uevent_encode_test.c")

    @tag :tmp_dir
    test "uevent encoder: dedup, cap, and well-formed terms", %{tmp_dir: tmp} do
      ei = to_string(:code.lib_dir(:erl_interface))
      cc = System.get_env("CC", "cc")
      out = Path.join(tmp, "uevent_encode_test")

      args =
        [
          "-std=gnu99",
          "-Wall",
          "-I",
          @c_src,
          "-I",
          Path.join(ei, "include"),
          @harness,
          "-L",
          Path.join(ei, "lib"),
          "-lei",
          "-lmnl",
          "-o",
          out
        ]

      {build_out, build_status} = System.cmd(cc, args, stderr_to_stdout: true)
      assert build_status == 0, "compiling the C harness failed:\n#{build_out}"

      {run_out, run_status} = System.cmd(out, [], stderr_to_stdout: true)
      assert run_status == 0, "C harness reported a failure:\n#{run_out}"
    end
  end
end
