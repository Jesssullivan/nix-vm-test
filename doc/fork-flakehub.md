# Fork FlakeHub Notes

This fork carries internal-only wiring for downstream consumers such as
`Jesssullivan/cmux`.

## Goals

- publish the fork to FlakeHub without making it broadly discoverable
- let downstream flakes consume the fork via a stable FlakeHub URL
- expose `lib.aarch64-linux` for multi-arch consumers while keeping upstream
  test coverage unchanged

## Publishing

The fork publishes through
[`.github/workflows/flakehub-publish.yml`](../.github/workflows/flakehub-publish.yml).

- `push` to `main` publishes a rolling FlakeHub release
- `workflow_dispatch` can be run from a non-`main` branch when a downstream
  repo needs to test a fork-only commit before merge
- visibility is `unlisted` so the flake is usable without assuming a paid
  private-flake plan
- `include-output-paths = true` enables resolved-store-path metadata for
  downstream FlakeHub consumers

## Downstream Usage

Example input for `cmux`:

```nix
{
  inputs.nix-vm-test.url = "https://flakehub.com/f/Jesssullivan/nix-vm-test/*";
}
```

## Current Caveats

- the fork exports `lib.x86_64-linux` and `lib.aarch64-linux`
- the fork still exports `checks` only for `x86_64-linux`
- Fedora test coverage in-tree is still x86_64-oriented, so enabling
  `checks.aarch64-linux` should be a separate change
