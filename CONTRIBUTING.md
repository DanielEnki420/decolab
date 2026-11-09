# Contributing

Decolab is a hobby project with one maintainer. Contributions are welcome;
answers and reviews come when time allows.

## How

- **Questions and ideas:** [Discussions](https://github.com/DanielEnki420/decolab/discussions).
  For anything bigger than a small fix, start there, before you write code.
- **Bugs:** [Issues](https://github.com/DanielEnki420/decolab/issues), with
  the release, what you did, what you expected and what happened.
- **Security problems:** never in public, see [SECURITY.md](SECURITY.md).
- **Changes:** a pull request against `main`. Small and focused is easier to
  review than large.

## What a change needs

1. **`tools/check.sh` passes.** It runs what CI runs: shellcheck, ruff and
   mypy, the guard against private data, gitleaks and the contract tests.
   Set it up once with `tools/setup-dev.sh`.
2. **Tests for new behaviour.** Every new function, option or fix comes with
   a contract test in `tests/` that checks what it promises (output, files,
   exit code, HTTP answer). A test must fail when the code is broken: check
   that by breaking the code once on purpose.
3. **Documentation in the same change.** A new setting goes into
   `decolab.conf.example`, `config/schema.txt` and INSTALL.md; a new service
   or job into the README and `docs/`.
4. **No private data.** No real IP addresses, host names, tokens or paths;
   examples use `192.0.2.0/24` and `2001:db8::/32`. The guard rejects most of
   it, but read your diff yourself.
5. **Pinned dependencies.** Container images by digest, GitHub Actions by
   commit SHA, Python tools by hash (`tools/requirements-lint.txt`). No
   release younger than one week.
6. **Plain code.** Bash or Python standard library; no new runtime
   dependencies without a reason in the pull request.

## Sign-off (DCO)

Every commit carries a `Signed-off-by:` line with your name, added by
`git commit -s`. With it you certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org/):
that you wrote the change or have the right to submit it under the
project's license. Pull requests without it are not merged.

Also read the [Code of Conduct](CODE_OF_CONDUCT.md) and, for who decides
what, [GOVERNANCE.md](GOVERNANCE.md).

## License

By contributing you agree that your contribution is licensed under the same
terms as the project: MIT or Apache-2.0, at the user's choice (see the
license files).
