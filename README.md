# OpenCode Smart Free Launcher

An installable Linux and Windows wrapper for OpenCode V2. Every new interactive
session is pinned to the highest-AA-ranked model that is currently verified as
free and tool-capable.

The launcher:

- filters the live Models.dev OpenCode Zen catalog to zero-input-cost,
  zero-output-cost, tool-capable models;
- ranks those candidates by Ebbwater's current Artificial Analysis index;
- uses AA position, context size, and OpenCode usage as tie-breakers/fallbacks;
- prints a prominent warning and reason whenever fallback mode is active;
- retries degraded selections after one hour and caches healthy selections for
  24 hours;
- creates each new V2 session with the selected model explicitly, preventing
  the shared OpenCode service from silently choosing a different default;
- preserves the model when continuing an existing session; and
- fails closed when it cannot verify that the selected model is free.

OpenCode sessions started through this wrapper should be treated as
non-confidential. Some free providers train on submitted prompts.

## Linux installation

Download the current Linux archive from the public release, verify it if you
want, then install:

```sh
curl -fLO https://github.com/bickbuilds/opencode-smart-free-launcher/releases/download/v0.1.2/opencode-smart-launcher-linux-0.1.2.tar.gz
curl -fLO https://github.com/bickbuilds/opencode-smart-free-launcher/releases/download/v0.1.2/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf opencode-smart-launcher-linux-0.1.2.tar.gz
cd opencode-smart-launcher-0.1.2
chmod +x install.sh
./install.sh
```

If OpenCode is missing, the installer downloads and runs the official V2
installer from `https://opencode.ai/v2/install`. It records the real binary,
installs `opencode-free` in `~/.local/bin`, and places an `opencode` symlink in
front of it. Existing regular files are never overwritten.

To uninstall only the wrapper while keeping OpenCode:

```sh
./install.sh --uninstall
```

Python 3 and curl are required. Python is used by the launcher; curl is only
needed when OpenCode itself must be installed.

## Windows installation

Download
[`opencode-smart-launcher-windows-0.1.2.zip`](https://github.com/bickbuilds/opencode-smart-free-launcher/releases/download/v0.1.2/opencode-smart-launcher-windows-0.1.2.zip),
extract it, open PowerShell in the extracted directory, and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

The installer reuses an existing OpenCode CLI when possible. If none exists,
it downloads the current native x64 or ARM64 V2 package identified by
OpenCode's official update feed and verifies the package's npm SHA-512
integrity before extracting `opencode.exe`. The wrapper directory is prepended
to the current user's PATH; open a new terminal afterward.

To uninstall only the wrapper while keeping OpenCode:

```powershell
.\install.ps1 -Uninstall
```

Windows PowerShell 5.1 or PowerShell 7 is supported. No Python installation is
required on Windows.

## Use and health checks

Start a new smart free-model session normally:

```sh
opencode
```

Check or refresh the current selection without opening the interface:

```sh
opencode-free --smart-free-status
opencode-free --smart-free-refresh --smart-free-status
```

Healthy output says `OK - Ebbwater AA ranking active`. A problem says
`DEGRADED - FALLBACK ACTIVE` and includes the reason. Every new launch also
prints the source, selected model, and AA snapshot before OpenCode opens.

`opencode -c` and `opencode -s <session>` preserve that session's existing
model. Commands such as `opencode auth`, `opencode models`, and `opencode
upgrade` pass directly to the real OpenCode binary.

Each machine needs its own OpenCode authentication:

```sh
opencode auth login
```

## Verification

Linux tests and syntax checks:

```sh
python3 -m unittest -v test_opencode_free.py
bash -n install.sh
```

## License and data sources

The launcher is released under the [MIT License](LICENSE). It bundles no
OpenCode binaries and no third-party model or benchmark datasets; those are
resolved from their public sources at install time or runtime. See
[third-party notices](THIRD_PARTY_NOTICES.md) for attribution and service
details.

This project is not affiliated with OpenCode, Ebbwater, Models.dev, or
Artificial Analysis. Free-model availability and third-party terms can change,
so the launcher re-verifies model price and capabilities before selection.
