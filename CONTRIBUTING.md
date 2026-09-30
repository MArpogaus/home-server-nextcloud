# Contributing

The branch flow, the hooks, the releases and the house style are in
`home-server/CONTRIBUTING.md`.

## Tags

A tag names the Nextcloud major that the release deploys, such as `35`. A
later release on the same major adds a counter: `35.1`, `35.2`.

## Checks in this repository

- Hooks: the basics, shellcheck, ansible-lint and commitizen.
- Ansible variables are `<role>_*`.
- Renovate updates the container image tags in the role defaults, through the
  preset that `.github/renovate.json` extends.
- `home-server` checks this repository out at `services/nextcloud`. Work on it
  there. `home-server/CONTRIBUTING.md` says how a change here reaches the pin.
