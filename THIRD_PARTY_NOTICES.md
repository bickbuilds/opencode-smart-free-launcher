# Third-party services and data

OpenCode Smart Free Launcher is independent software. Its source and release
archives do not contain OpenCode binaries, Ebbwater pages, Artificial Analysis
benchmark data, or a copy of the Models.dev catalog.

At runtime, the launcher interoperates with these public services:

- [OpenCode](https://opencode.ai/) is installed separately from OpenCode's
  official distribution. OpenCode's source code is available under the MIT
  License. OpenCode is a trademark or project name of its respective owner.
- [Models.dev](https://models.dev/) provides the live model catalog used to
  verify zero input cost, zero output cost, and tool support. Models.dev's
  repository and catalog are published under the MIT License, copyright 2025
  models.dev.
- [Ebbwater OpenCode PriceWatch](https://www.ebbwater.net/tools/opencode)
  provides a public, timestamped view of Artificial Analysis Intelligence
  Index values. The launcher reads the current public page at runtime and does
  not bundle or republish its page, branding, or a static benchmark dataset.
- [OpenCode Stats](https://stats.opencode.ai/) supplies a public usage signal
  only when the Ebbwater ranking cannot be used.

Artificial Analysis benchmark names and data, the Ebbwater name and mark, and
all other third-party names and marks belong to their respective owners. This
project is not affiliated with, endorsed by, or sponsored by OpenCode,
Ebbwater, Models.dev, or Artificial Analysis.

Use of the live services remains subject to each service owner's current terms
and availability. The launcher caches only the selected model and the small
amount of source metadata needed to explain that selection.
