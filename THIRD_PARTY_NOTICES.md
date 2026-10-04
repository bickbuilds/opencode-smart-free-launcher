# Third-party services and data

OpenCode Smart Free Launcher is independent software. Its source and release
archives do not contain OpenCode binaries, Artificial Analysis benchmark data, or
a copy of the Models.dev catalog.

At runtime, the launcher interoperates with these public services:

- [OpenCode](https://opencode.ai/) is installed separately from OpenCode's
  official distribution. OpenCode's source code is available under the MIT
  License. OpenCode is a trademark or project name of its respective owner.
- [Models.dev](https://models.dev/) provides the live model catalog used to
  verify zero input cost, zero output cost, and tool support. Models.dev's
  repository and catalog are published under the MIT License, copyright 2025
  models.dev.
- [Artificial Analysis](https://artificialanalysis.ai/data-api) supplies the
  published index values used to rank the free models. The launcher queries the
  free-tier API endpoint at runtime with a user-supplied API key and does not
  bundle or republish benchmark data. Use of the API requires attribution to
  Artificial Analysis and is subject to their Terms of Use and Data Platform
  Terms.
- [OpenCode Stats](https://stats.opencode.ai/) supplies a public usage signal
  only when the Artificial Analysis ranking cannot be used.

Artificial Analysis benchmark names and data, and all other third-party names and
marks belong to their respective owners. This project is not affiliated with,
endorsed by, or sponsored by OpenCode, Models.dev, or Artificial Analysis.

Use of the live services remains subject to each service owner's current terms
and availability. The launcher caches only the selected model and the small
amount of source metadata needed to explain that selection. The API key is read
from the `ARTIFICIAL_ANALYSIS_API_KEY` environment variable at runtime and is
never written to the cache or to disk by the launcher.
