# Contributing to NotchBar

Thanks for wanting to help. Whether it's a bug report, an idea, a typo fix or a new feature, every contribution makes NotchBar better. This guide shows you how to get started, even if this is your first open source contribution.

By taking part, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Contents

- [Ways to help](#ways-to-help)
- [Reporting a bug](#reporting-a-bug)
- [Suggesting a feature](#suggesting-a-feature)
- [Setting up your Mac](#setting-up-your-mac)
- [Making a change](#making-a-change)
- [What makes a change easy to accept](#what-makes-a-change-easy-to-accept)
- [Opening a pull request](#opening-a-pull-request)
- [After you open it](#after-you-open-it)
- [Security issues](#security-issues)
- [License of contributions](#license-of-contributions)

## Ways to help

You don't need to write code to help.

| You can | How |
|---|---|
| Report a bug | [Open a bug report](https://github.com/srisanthosh/NotchBar/issues/new?template=bug_report.yml) |
| Suggest a feature | [Open a feature request](https://github.com/srisanthosh/NotchBar/issues/new?template=feature_request.yml) |
| Improve the docs | Edit `README.md` or this file and open a pull request |
| Test on your Mac | Try NotchBar on a different Mac model or macOS version and tell us what you find |
| Fix a bug or build a feature | Pick an issue labelled `good first issue` or `help wanted`, then follow the steps below |

If you want to work on something, comment on its issue first so two people don't build the same thing. For a big change, open an issue to discuss it before you start.

## Reporting a bug

[Search the issues](https://github.com/srisanthosh/NotchBar/issues) first, in case someone has reported it already. If not, open a [bug report](https://github.com/srisanthosh/NotchBar/issues/new?template=bug_report.yml) and include:

- Your Mac model, such as "MacBook Pro 14-inch, M3", and your macOS version.
- What you did, what you expected, and what happened instead.
- A screenshot or screen recording, if the bug is visual.
- For media, dictation or headphone bugs, the app or device involved, such as "YouTube in Chrome" or "Galaxy Buds2 Pro".

For harder bugs, the debug state helps a lot. Start NotchBar in debug mode, reproduce the problem, then save the state:

```bash
open --env NOTCHBAR_DEBUG=1 build/NotchBar.app
scripts/debug.sh state:/tmp/notchbar-state.json
```

Look through the file before you attach it. It contains the titles of what's playing and your Chrome tab names.

## Suggesting a feature

Open a [feature request](https://github.com/srisanthosh/NotchBar/issues/new?template=feature_request.yml). Describe the problem you want solved, not only the solution you have in mind. That makes it easier to find a design that fits NotchBar. Check the [Roadmap](README.md#roadmap) too, as it may be planned already.

## Setting up your Mac

You need a Mac with a notch running macOS 14 or later, and the Swift toolchain. The Xcode Command Line Tools are enough:

```bash
xcode-select --install
```

Then:

1. **Fork** the repository. Click **Fork** at the top of the GitHub page to get your own copy.
2. **Clone** your fork:
   ```bash
   git clone https://github.com/<your-username>/NotchBar.git
   cd NotchBar
   ```
3. **Create a signing certificate** (optional, but recommended). Without one, macOS forgets NotchBar's Accessibility and Automation permissions after every build:
   ```bash
   scripts/setup-signing.sh
   ```
4. **Build and run:**
   ```bash
   ./build.sh --run
   ```

The [Development](README.md#development) section of the README lists more commands, and [Project layout](README.md#project-layout) explains where things live.

## Making a change

1. **Create a branch** from `main` with a short, descriptive name:
   ```bash
   git checkout -b fix-spotify-artwork
   ```
2. **Make your change.** Keep each pull request to one fix or feature. Small pull requests get reviewed faster.
3. **Check it visually.** Render every state with sample data and look at the ones you touched, in both the open and the closed notch:
   ```bash
   swift build -c release && .build/release/NotchBar --snapshot ./snapshots
   ```
4. **Check it live.** Run `./build.sh --run` and try your change for real. The debug commands help here. For example, `scripts/debug.sh airpods` shows the headphone banner without needing headphones.
5. **Measure it** if your change runs in the background. Compare before and after:
   ```bash
   top -l 2 -s 60 -pid $(pgrep -x NotchBar) -stats pid,cpu,idlew,power,mem | tail -1
   ```
6. **Commit** with a message that says what changed and why:
   ```bash
   git commit -m "Show Spotify artwork when the track changes while paused"
   ```

## What makes a change easy to accept

NotchBar aims to feel like part of macOS and to cost almost no battery. These rules keep it that way.

**Native and dependency-free.** Use Apple's frameworks: SwiftUI, AppKit, CoreAudio, EventKit and so on. Please don't add Swift packages.

**Events, not timers.** Listen for system notifications instead of checking on a timer. If you must poll, poll only while the feature is visible or in use, and use `EfficientTimer` so it pauses while the Mac sleeps. Pull requests that raise CPU at rest above about 0.1% won't be merged.

**Private by default.** Nothing leaves the Mac unless the user turns it on, as with weather. Never read passwords, tokens or keychain items, and never call private endpoints with someone's account.

**Matches the code around it.** Follow the existing shape: a `@MainActor` `ObservableObject` owns a feature's state, and SwiftUI views observe it. Use the same naming, comment style and formatting as nearby code. Comments explain why, not what.

**Looks like Apple made it.** Use system fonts and SF Symbols, smooth spring animations, and layouts that stay balanced around the camera. When in doubt, compare with Dynamic Island on iPhone.

**Plain, clear wording.** Interface text should be short and friendly. Say "Couldn't connect" rather than "Error: connection failed".

## Opening a pull request

1. Push your branch to your fork:
   ```bash
   git push -u origin fix-spotify-artwork
   ```
2. On GitHub, click **Compare & pull request**.
3. Fill in the template: what changed, why, how you tested it, and screenshots for anything visual.
4. Link the issue it fixes by writing `Fixes #123` in the description.

Draft pull requests are welcome if you want early feedback.

**The automatic check.** Every pull request is built on a Mac by GitHub Actions. You'll see **Build and snapshot** at the bottom of the pull request. A green tick means it built. A red cross means it didn't: click **Details** to see the error, fix it, and push again. The check also renders every snapshot screenshot. To look at them, open **Details**, then **Summary**, and download **snapshots** under Artifacts.

## After you open it

A maintainer will review your pull request, usually within a week. Reviews may ask for changes. That's normal and not a judgement of your work. Push new commits to the same branch and the pull request updates itself.

Once it's approved, a maintainer merges it, and you'll be listed among the repository's contributors. Thank you!

## Security issues

Please don't report security problems in public issues. See [SECURITY.md](SECURITY.md) for how to report them privately.

## License of contributions

NotchBar is released under the license in [LICENSE](LICENSE). By submitting a pull request, you agree that your contribution is licensed under the same terms, and that you have the right to submit it.
