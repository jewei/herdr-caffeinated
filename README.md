# herdr-caffeinated

A [herdr](https://herdr.dev/) plugin that keeps macOS awake while the herdr
server runs, so your agents keep working when the screen locks or the Mac
goes idle.

## How it works

When the herdr server starts, a startup hook runs:

```sh
caffeinate -ims -w <herdr-server-pid>
```

- `-i` prevents idle system sleep.
- `-m` prevents disk idle sleep.
- `-s` prevents system sleep (macOS honors this only on AC power).
- `-w` ties the assertion to the herdr server. When the server exits, the
  assertion is released. No orphan processes.

The display can still sleep and the screen can still lock. Your herdr
sessions keep running behind the lock screen.

## Install

```sh
herdr plugin install jewei/herdr-caffeinated
# or, from a local checkout:
herdr plugin link /path/to/herdr-caffeinated
```

The startup hook runs on the next server start. To activate it now:

```sh
herdr plugin action invoke jewei.caffeinated.start
```

## Actions

| Action                         | Effect                                     |
| ------------------------------ | ------------------------------------------ |
| `jewei.caffeinated.toggle`     | Switch keep-awake on or off                |
| `jewei.caffeinated.start`      | Keep the Mac awake                         |
| `jewei.caffeinated.stop`       | Allow sleep. Stays paused across restarts. |
| `jewei.caffeinated.status`     | Show the current state                     |

Bind one to a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "super+shift+c"
type = "plugin_action"
command = "jewei.caffeinated.toggle"
description = "toggle caffeinate"
```

## Configuration

Create `config` in the plugin config directory
(`herdr plugin config-dir jewei.caffeinated`). See `config.example`.

```sh
CAFFEINATE_FLAGS="-dims"  # also keep the display on
NOTIFY=0                  # no herdr toasts from actions
```

## Limits

`caffeinate` cannot override every kind of sleep:

- **Lid closed on battery.** macOS sleeps anyway. On AC power with an
  external display (clamshell mode), `-s` keeps the Mac awake.
- **Low battery or thermal events.** macOS can still force sleep.
- **Manual sleep** (Apple menu > Sleep) is not blocked.

To block sleep with the lid closed on battery, you need a system setting
that needs admin rights, for example `sudo pmset -a disablesleep 1`. This
plugin does not change system settings.

## Logs

- herdr command logs: `herdr plugin log list --plugin jewei.caffeinated`
- plugin log: `$HERDR_PLUGIN_STATE_DIR/caffeinated.log`
