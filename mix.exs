defmodule NervesUEvent.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/nerves-project/nerves_uevent"

  def project do
    [
      app: :nerves_uevent,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["mix_clean"],
      make_error_message: """
      If the error message above says that libmnl.h can't be found, then the
      fix is to install libmnl. For example, run `apt install libmnl-dev` on
      Debian-based systems. For Nerves targets, be sure to include 
      `BR2_PACKAGE_LIBMNL=y` in the Buildroot defconfig
      """,
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      deps: deps(),
      preferred_cli_env: %{docs: :docs, "hex.build": :docs, "hex.publish": :docs}
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {NervesUEvent.Application, []}
    ]
  end

  defp deps do
    [
      {:property_table, "~> 0.2.0 or ~> 0.3.0"},
      {:elixir_make, "~> 0.6", runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:credo, "~> 1.5", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp description do
    "Simple UEvent monitor for detecting hardware and automatically loading drivers"
  end

  defp package do
    [
      files: [
        "CHANGELOG.md",
        "c_src/*.[ch]",
        "lib",
        "LICENSES/*",
        "Makefile",
        "mix.exs",
        "NOTICE",
        "README.md"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "REUSE Compliance" =>
          "https://api.reuse.software/info/github.com/nerves-project/nerves_uevent"
      }
    ]
  end

  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs]
    ]
  end
end
