# Contributing

Work on `dev`. `main` takes a merge from `dev` with `--no-ff`.

Write conventional commits. The commitizen hook rejects a message that does not
follow the format.

Install the hooks in this repository:

```bash
pre-commit install --install-hooks -t pre-commit -t commit-msg -t pre-push
```

Plain `pre-commit install` installs the pre-commit stage alone, and the commit
message and branch hooks then do not run. CI runs the pre-commit stage hooks on
a push and on a pull request.

Every GitHub action is pinned to a commit SHA. Dependabot updates the actions
and the hook revisions weekly against `dev`. `pinact run -u` updates and
re-pins the actions by hand.

## Releases

A release is a merge of `dev` into `main`, then an annotated tag on the merge
and `git push --follow-tags`. The `release` workflow turns every pushed tag into
a GitHub release. GitHub writes its notes: the pull requests merged since the
previous release and a link that compares the two tags.

A tag names the Nextcloud major that the release deploys, such as `35`. A
later release on the same major adds a counter: `35.1`, `35.2`.

## House style

A comment says why, never what. Longer reasoning belongs in the README of the
repository that owns the code. Write the prose in Simplified Technical English:
short sentences, one meaning per word, and the condition before the command.

## Checks in this repository

- Hooks: the basics, shellcheck, ansible-lint and commitizen.
- Ansible variables are `<role>_*`.
- Renovate updates the container image tags in the role defaults, through the
  preset that `.github/renovate.json` extends.
- This repository is checked out in `home-server/services/nextcloud`, where you work
  on it. `home-server/CONTRIBUTING.md` says how a change reaches the pinned
  version.
