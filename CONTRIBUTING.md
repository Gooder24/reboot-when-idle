# Contributing

Thanks for looking at reboot-when-idle. Before you open a pull request:

1. Run `make check`. It checks the syntax and runs the self-test, in a few seconds, without root.
2. Run `make test`. It runs the scenarios on your machine, takes about a minute, and reboots nothing. One scenario uses `sudo -n`; it is skipped when passwordless sudo is not set up.
3. If you changed Markdown, run `python3 .github/scripts/check-docs.py`. It must report no new problems.
4. Fill in the accessibility part of the pull request template.

What we expect for accessibility, and how to report a barrier, is in [ACCESSIBILITY.md](ACCESSIBILITY.md#contributor-expectations).
