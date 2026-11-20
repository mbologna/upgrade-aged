# AGENTS.md

Notes for coding agents working in this repository. [README.md](README.md) covers what it does and how to use it.

## Versioning

Unversioned, per the [versioning standard](https://github.com/mbologna/.github/blob/main/VERSIONING.md): no tags and no releases, and users clone `main`.

- Never create tags: this repository has no releases; `main` is used as is.
- The scripts and `lib/` are mirrored from the private dotfiles repository, which pushes a commit (`chore: sync from dotfiles@<sha>`) whenever a mirrored file changes there, so an edit made to them here is overwritten by the next sync. README.md, LICENSE and this file live only here.
