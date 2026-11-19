# Accessibility

reboot-when-idle is a command-line tool. People run it from a terminal, often over SSH on a machine nobody sits in front of, so its commands, output and messages have to work from a keyboard, in plain text, with a screen reader or a braille display. Everyone who installs, runs or fixes it should be able to do that without a mouse, without relying on colour, and without guessing what the output means.

This file says what we aim for, how to report a barrier, and what has been checked and what has not.

## Priorities

- **Scope:** the command line only. The tool has no graphical interface and no web page. The Web Content Accessibility Guidelines (WCAG) are written for web and software interfaces, and we do not claim conformance to them.
- **Keyboard:** everything is done by typing commands. Nothing needs a mouse. No command asks a question or waits for a keypress; `hook` reads the event that an agent sends on standard input.
- **Plain text:** the tool writes no colour and no escape codes. Each state is written in words.
- **Readable docs:** the README and this file use headings in order, descriptive link text and table header cells with text.

## Contributor expectations

If you change the tool or its documentation:

- Keep the output plain text. Do not show a state with colour or a symbol alone. Each line says what happened in words.
- Write messages that say what happened and what to do next.
- Run `make check` and `make test`, as described in [CONTRIBUTING.md](CONTRIBUTING.md).
- Run `python3 .github/scripts/check-docs.py`. It must report no new problems.
- In documentation, keep heading levels in order, use link text that says where the link goes (not "here"), and give every table header cell text.
- Fill in the accessibility part of the pull request template.

## Reporting an accessibility barrier

1. Open an issue with the [accessibility issue form](https://github.com/Gooder24/reboot-when-idle/issues/new?template=accessibility.yml).
2. Say what you tried to do, the command and its output, your distribution and terminal, and any assistive technology with its version. Leave out host names, IP addresses and tokens.
3. Choose a severity, below. You do not have to say why you use a tool or what your needs are.
4. If the form does not work for you, open an ordinary issue with the same details.

### Severity

- **Critical:** you cannot complete a task at all.
- **Serious:** you can complete it, but only with a workaround.
- **Moderate:** you can complete it, but the experience is inconsistent or annoying.
- **Minor:** a small problem with little effect on the task.

### How we respond

- We acknowledge a report in its issue when we see it. The project has one maintainer and no fixed response time.
- We add the `accessibility` label, the severity, and the owner.
- Where we can, we suggest a workaround while a fix is in progress.
- We say when the status or the expected timeline changes, and we ask you to confirm a fix before we close the issue, if you are able to.

### Owner

Accessibility is owned by **Gooder24**, the repository maintainer. The owner:

- triages accessibility reports and labels them,
- tracks open accessibility issues and known barriers,
- keeps this file and the checks in `.github/` current.

## Testing

On every pull request and every push to `main` that changes a Markdown file or the check itself, [`.github/workflows/accessibility.yml`](.github/workflows/accessibility.yml) runs `check-docs.py` over the Markdown files. Known problems are listed in `.github/a11y-baseline.json`; a new problem fails the check.

| Check | Status | Record (2026-11-16, Debian 13) |
|---|---|---|
| Automated docs check | done | `check-docs.py`: no problems at baseline |
| Keyboard-only smoke test | done | `--self-test`, `status`, `hold` and the usage text (no arguments) typed into a terminal with keystrokes only, no mouse; exit codes 0, 0, 0 and 2 |
| Terminal width | done for `status` | at 40 columns all the text of `status` is there; the terminal wraps the long lines |
| Colour | done | the tool writes no colour and no escape codes; its messages were read through |
| Screen reader spot check | done, 2026-11-19 | Orca 48.1 on the README in Chromium 156 and on the commands in lxterminal; one fix, one barrier left ([#4](https://github.com/Gooder24/reboot-when-idle/issues/4)); see below |
| Zoom | not run | the text size is set by the terminal program |
| Documentation review | done | README and this file read by hand; the empty table headers of [#1](https://github.com/Gooder24/reboot-when-idle/issues/1) are fixed, and the screen reader reads every column header |

### Screen reader spot check (19 November 2026)

Orca 48.1 with speech-dispatcher 0.12.0 on Debian 13 (thinkpad-e540): the README as GitHub renders it, in
Chromium 156, and these commands typed into lxterminal:

    reboot-when-idle --self-test
    reboot-when-idle status
    reboot-when-idle hold true; echo "exit $?"

An agent ran it with `citacka` (karchi-skills), which writes down the text Orca sends to the synthesizer: the
words, not the voice. Default Orca settings, key echo off. The transcripts are in [this gist](https://gist.github.com/Gooder24/9816e5601781f40a5e0656c79b9b5252).

- **README:** 13 headings, each read with its level, then GitHub's "Permalink" link; 6 links of its own, each named by its text; the three tables read
  with their size and the column header of every cell.
- **Fixed:** the Commands section was a code block in which each command ran into its description, read as
  one sentence. It is a list now (`83e0ffa`).
- **Commands:** `--self-test`, `hold` and the exit code are read in full. `status` is read line by line, but
  the work in login sessions is one long line: [#4](https://github.com/Gooder24/reboot-when-idle/issues/4).
- **Not checked:** NVDA, VoiceOver, a braille display, and how a voice pronounces the symbols in code.

## Supported environments

- **Run on:** Debian 13 on an x86_64 laptop, with systemd, bash and GRUB installed. The scenario tests stand in for GRUB and the reboot, so a real kernel trial has not been run here.
- **Not tested:** other Linux distributions, other shells and terminal programs, and assistive technology other than Orca (see the spot check above).

## Known limitations

- `status` lists the work in login sessions on one long line, which is slow to follow by ear. Tracked in [#4](https://github.com/Gooder24/reboot-when-idle/issues/4).
- The screen reader check was a transcript of Orca's speech, not a person listening: NVDA, VoiceOver and braille are not tested.
- The automated check reads Markdown only. It does not check the tool's output, table header cells, link targets or code blocks. Tables and code blocks are reviewed by hand; link targets are not reviewed yet.

## Dependencies

reboot-when-idle depends on systemd, procps, iproute2 and awk, and recommends unattended-upgrades and grub-common (see `packaging/control`). None of them is a user interface that this project adds. A new dependency with an interface of its own is reviewed for accessibility before it is added, and any barrier it has is written here with its workaround.

## Recognition and progress

- A contributor is named in a release note only with their consent.
- A release that changes accessibility says so in its release notes and links the open accessibility issues.

## Shared resources

The issue form, the pull request checklist and `.github/scripts/check-docs.py` (needs only Python 3.8 or later and git) can be reused in other projects. Owner: Gooder24.
