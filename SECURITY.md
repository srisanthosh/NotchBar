# Security Policy

NotchBar has access to sensitive things on your Mac: your clipboard, your calendar, what's playing, and, if you allow it, Accessibility. We take problems with any of these seriously.

## Reporting a vulnerability

**Please don't open a public issue for security problems.** Report them privately instead:

1. Go to the repository's [Security tab](https://github.com/srisanthosh/NotchBar/security).
2. Click **Report a vulnerability**.
3. Describe the problem, how to reproduce it, and what an attacker could do with it.

Only the maintainer can see the report. You'll get a reply within a week, and we'll keep you updated until it's fixed. If you'd like credit, we'll thank you in the release notes once the fix is out.

## What counts

For example:

- NotchBar leaks clipboard, calendar or media data to another app, a file other users can read, or the network.
- Clipboard history keeps items that password managers marked as concealed.
- The Claude Code integration changes `~/.claude/settings.json` in ways the user didn't ask for, or runs commands it shouldn't.
- Debug commands work without `NOTCHBAR_DEBUG=1`.

## Supported versions

Only the latest version on the `main` branch gets security fixes.
