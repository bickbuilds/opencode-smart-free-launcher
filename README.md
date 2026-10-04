# OpenCode Smart Free Launcher

An installable Linux and Windows wrapper for OpenCode V2. Every new interactive
session is pinned to the highest-ranked model that is currently verified as free
and tool-capable.

The launcher:

- filters the live Models.dev OpenCode Zen catalog to zero-input-cost,
  zero-output-cost, tool-capable models;
- ranks those candidates using the official Artificial Analysis API, preferring
  the Coding Agent Index and falling back to the Agentic and Intelligence
  indices when a model has no value for the preferred one;
- matches OpenCode Zen model ids against publisher model names by stripping
  Zen-only qualifiers such as `-free` and `-contributor-free`;
- ranks on a single index at a time, since the Coding, Agentic and Intelligence
  indices are separately calibrated and not directly comparable;
- uses context size and OpenCode usage as tie-breakers/fallbacks;
- reports benchmark coverage on every status check, naming free models the
  publisher has not scored, so a successful ranking never implies that every
  available model was considered;
- prints a prominent warning and reason whenever fallback mode is active;
- retries degraded selections after one hour and caches healthy selections for
  24 hours;
- creates each new V2 session with the selected model explicitly, preventing
  the shared OpenCode service from silently choosing a different default;
- preserves the model when continuing an existing session; and
- fails closed when it cannot verify that the selected model is free.

OpenCode sessions started through this wrapper should be treated as
non-confidential. Some free providers train on submitted prompts.

## Artificial Analysis API key

Ranking uses the official Artificial Analysis API and requires a free API key:

```sh
export ARTIFICIAL_ANALYSIS_API_KEY="your-key-here"
```

Create a key at [artificialanalysis.ai/data-api](https://artificialanalysis.ai/data-api).
The key is read from the environment at runtime and is never written to the
launcher's cache or to disk. On Windows, set it as a user environment variable.

Without a key the launcher still runs, but ranking degrades to the OpenCode usage
fallback and reports `DEGRADED - FALLBACK ACTIVE` with the reason. Attribution to
Artificial Analysis is required when you use their API; see
[third-party notices](THIRD_PARTY_NOTICES.md).

## Linux installation

Download the current Linux archive from the public release, verify it if you
want, then install:

```sh
curl -fLO https://github.com/bickbuilds/opencode-smart-free-launcher/releases/download/v0.1.5/opencode-smart-launcher-linux-0.1.5.tar.gz
curl -fLO https://github.com/bickbuilds/opencode-smart-free-launcher/releases/download/v0.1.5/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf opencode-smart-launcher-linux-0.1.5.tar.gz
cd opencode-smart-launcher-0.1.5
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
[`opencode-smart-launcher-windows-0.1.5.zip`](https://github.com/bickbuilds/opencode-smart-free-launcher/releases/download/v0.1.5/opencode-smart-launcher-windows-0.1.5.zip),
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
required on Windows. When Git Bash is present, the installer also places
managed entry points in `~/bin` so the same `opencode` and `opencode-free`
commands work immediately in existing and new Git Bash terminals.

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

Healthy output says `OK - Artificial Analysis ranking active`. A problem says
`DEGRADED - FALLBACK ACTIVE` and includes the reason. Every new launch also
prints the index used, the selected model, and the Artificial Analysis index
version before OpenCode opens.

Status output also reports how much of the free catalog Artificial Analysis has
actually scored, and names the models it has not:

```
Coverage: 5 of 10 free models scored by AA
Not scored by AA (5): big-pickle, fledge-alpha-free, ...
```

Unscored models cannot be ranked on benchmark data, so they are never selected
on that basis. If *no* free model is scored, the launcher falls back to OpenCode
usage rankings rather than failing. Popularity is not treated as a quality
signal, since it reflects availability and promotion as much as capability.

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

Windows tests (PowerShell 5.1 or 7):

```powershell
.\test\windows\test-launcher.ps1
.\test\windows\test-aa-ranking.ps1
.\test\windows\test-installer.ps1
```

The ranking tests do not require an API key; they exercise the selection logic
against fixed responses.

## License and data sources

The launcher is released under the [MIT License](LICENSE). It bundles no
OpenCode binaries and no third-party model or benchmark datasets; those are
resolved from their public sources at install time or runtime. See
[third-party notices](THIRD_PARTY_NOTICES.md) for attribution and service
details.

This project is not affiliated with OpenCode, Models.dev, or Artificial
Analysis. Free-model availability and third-party terms can change, so the
launcher re-verifies model price and capabilities before selection.
