# Governance

Decolab is a small hobby project. This page says who decides, who can do
what, and what happens if the maintainer is gone.

## Roles

| Role | Who | Can |
|---|---|---|
| Maintainer | `DanielEnki420` | decides on changes and releases, signs release tags, answers security reports |
| Successor | `relative23` | no rights in daily work; GitHub's designated successor for the maintainer's account (see below) |
| Contributor | anyone | opens issues, discussions and pull requests ([CONTRIBUTING.md](CONTRIBUTING.md)) |

## How decisions are made

The maintainer decides. Larger changes are discussed first in
[Discussions](https://github.com/DanielEnki420/decolab/discussions) or in
the issue, so the reasons stay public. A change lands when `tools/check.sh`
and CI pass and the maintainer merges it. Releases are tagged and signed by
the maintainer.

## Continuity

If the maintainer cannot continue for good, the project does not depend on
his password. He has named a successor through GitHub's successor setting:
GitHub gives the successor access to the maintainer's repositories, without
the maintainer's credentials. The successor then either hands the repository
to a new maintainer (transfer) or archives it with a note in the README, so
users know where they stand. Issues, discussions and the full history stay
public in either case, and anyone may fork the project under its license.

One thing does not carry over on purpose: the release signing key. Installed
systems accept only release tags signed by a key in
`/etc/decolab/release-signers`. A new maintainer signs with a new key,
announces it in a release note and in the README, and users add it
themselves after checking it. Until then `update.sh` refuses the new
releases. This keeps a taken-over account from shipping code to existing
installations.

The bus factor is one: one person develops Decolab. Continuity of access is
secured by the successor setting.
