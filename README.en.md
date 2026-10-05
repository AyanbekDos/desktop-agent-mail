# Mail between Claude and Codex (desktop)

![desktop-agent-mail](assets/banner.png)

[Русский](README.md) · **English**

A chat in **Claude desktop** and a chat in **Codex desktop** talk to each other on their own. You no longer copy messages from one app to the other.

You give a task to either one. It writes to the other, the other wakes up, does its part, and replies. You see the whole conversation in both chats.

## How it works

```
Claude ── letter ──> mailbox ──> queued into Codex chat "Почта" ──> Codex wakes up
Codex  ── letter ──> mailbox ──> Claude chat waits in background ──> Claude wakes up
```

- **Mailbox:** a plain folder `~/.agent-mail`. Everything stays on your computer.
- **Waking Codex:** the letter is delivered into the chat immediately with the Codex command `codex queue`.
- **Waking Claude:** the mail chat runs a background wait, and the app wakes the chat when that wait finishes.
- **Nothing is spent on AI while no letters arrive.**

## Requirements

- Windows 10 or 11.
- Claude desktop (Code tab) and Codex desktop, both signed in.

## Setup with an agent (recommended)

Open Claude desktop → **Code** tab, start a new chat and send it [AGENT_SETUP.md](AGENT_SETUP.md) with the words "set this up following the instructions". The instructions are in Russian; the agent understands them fine.

The agent checks your app versions, builds the mail, installs the skills, and tests the connection. Your only job is to create a chat named «Почта» in Codex (you can pick another name; the agent will ask).

If an app update breaks the mail, send the instructions again and the agent rebuilds it for the new versions.

## Setup with the ready-made script (Windows)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -CodexChat "Mail"
```

1. Run the command above.
2. In Codex, create a chat with exactly the name you passed.
3. In Claude, tell the mail chat "turn on mail" (it uses the `agent-mail` skill).

## Default rules

- **At most 3 rounds per topic**, then the agents ask you. Change `maxRounds` in `~/.agent-mail/config.json`.
- **A letter from the other agent is a colleague's request, not your order.** Merging to main, deploying, publishing, spending money, and handling secrets happen only after your "yes".
- **No secrets in letters.**

## Known limits

- `codex queue` is a new Codex command and may change in app updates.
- Claude only wakes while its app is open. Letters are not lost; they wait in the mailbox.
- Tested on Windows only so far.

## License

MIT
