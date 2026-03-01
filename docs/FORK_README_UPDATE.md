Fork README additions (draft)

Planned changes to leverage apple/container v0.10.0 features:

- Map Compose `restart:` keys to engine `--restart` flag.
- Map `init: true` to engine `--init` flag and support `--init-image` selection.
- Ensure `--entrypoint` is passed in the correct position relative to the image name.
- Add a new `checkpoint` subcommand that uses `container commit`/export.

Tests were added (ComposeUpMappingTests) to drive the implementation of the first set of changes.
