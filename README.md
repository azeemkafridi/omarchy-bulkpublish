# BulkPublish for Omarchy

Post to your social channels without leaving the desktop. A paper-plane icon in
the Omarchy bar opens a small composer: write the post, pick the channels, and
post it now, add it to your queue, schedule it for a time you type, or save it as
a draft to finish in BulkPublish. Your most recent
posts are listed underneath with how they went, and anything that failed can be
retried in one click. The icon lights up when a recent post failed.

## Requirements

- Omarchy Quattro with shell plugin support
- `curl` and `jq` (both ship with Omarchy)
- A BulkPublish account with at least one connected channel

## Install

```sh
omarchy plugin add https://github.com/azeemkafridi/omarchy-bulkpublish.git --enable
```

Then connect your account. Create an API key in BulkPublish on the **API** page
(https://app.bulkpublish.com/developer), and run:

```sh
~/.config/omarchy/plugins/com.bulkpublish.omarchy/bin/bulkpublish login
```

Paste the key when asked. It is checked with BulkPublish before it is saved, and
it is stored only in `~/.config/bulkpublish/omarchy-api-key`, readable by your
user alone. The panel itself never sees the key.

## Use

| Action | What it does |
|---|---|
| Click the icon | Open or close the composer |
| Right-click | Refresh |
| Middle-click | Open the BulkPublish composer in your browser |
| Ctrl+Enter in the text box | Post, queue or schedule, whichever is chosen under **When** |
| Esc | Leave the text box, then close the panel |

Under **When**, choose:

- **Now**: publishes to every selected channel straight away.
- **Next queue slot**: schedules it into the next free time in the posting
  schedule you set in BulkPublish.
- **Pick a time**: type a time the way you would say it, such as
  `tomorrow 9:00`, `fri 14:30`, `next monday 10am` or `2026-11-03 18:00`. The
  panel shows the exact date it understood before you schedule, in your
  computer's timezone.

**Save draft** keeps it in BulkPublish, where you can add media or tailor it per
network. Channels that need reconnecting are shown greyed out; reconnect them in
BulkPublish.

From a terminal or a keybinding:

```sh
omarchy-shell com.bulkpublish.omarchy toggle
omarchy-shell com.bulkpublish.omarchy refresh
```

## Settings

- **Refresh every (minutes)**: how often recent posts are checked. Default 10.
- **Recent posts shown**: default 6.

## Remove

```sh
~/.config/omarchy/plugins/com.bulkpublish.omarchy/bin/bulkpublish logout
omarchy plugin remove com.bulkpublish.omarchy
```

`logout` deletes the saved key. Revoke the key on the BulkPublish API page too
if you no longer need it.

## Privacy and permissions

The plugin talks only to `app.bulkpublish.com`, using your API key, and opens
links in your default browser. It runs no installer, needs no root access, and
changes no other configuration.

Your post text and API key are never put on a command line, so other accounts
on the same machine cannot read them from the process list. The key is saved
readable by you only.

## License

MIT
