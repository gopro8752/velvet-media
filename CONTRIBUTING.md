# Contributing

Velvet is source available for personal and noncommercial use under [LICENSE](LICENSE).
Contributions to the original project code are submitted under those same terms;
you retain copyright in your own contribution. Do not submit third-party code
without a compatible license and its required notices.

Please describe the problem, the expected behavior, and the platforms you tested.
Keep changes focused and follow the existing UI conventions: clear remote focus,
predictable navigation, readable content, and accessible controls. Roku remains
alpha; identify the model and OS when reporting hardware-specific failures.

Before submitting:

1. Run the relevant client/backend tests from its README.
2. Run `python3 scripts/publication_guard.py` and a secret scan.
3. Check that source examples contain no real endpoints, account keys, profiles,
   device IDs, local user paths, or signing material.
4. Include third-party notices when adding dependencies or assets.

Use synthetic fixtures for playback, telemetry, and profile tests. Do not paste
unredacted server logs or personal viewing history into issues. Follow
[SECURITY.md](SECURITY.md) for sensitive reports.
