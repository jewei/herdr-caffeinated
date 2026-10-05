# Herdr Caffeinated

A [herdr](https://herdr.dev/) plugin that keeps macOS awake while your agents
work. Lock the screen or walk away: agents keep running. When every agent
stops working, the Mac can sleep again.

## How it works

Herdr runs `bin/caffeinated.sh reconcile` at server startup and on these
events: `pane.agent_status_changed`, `pane.agent_detected`, `pane.exited`,
`pane.closed`.

- When any agent is `working`, the plugin starts
  `/usr/bin/caffeinate -ims -w <herdr-server-pid>`.
  - `-i` prevents idle system sleep.
  - `-m` prevents disk idle sleep.
  - `-s` prevents system sleep (macOS honors this only on AC power).
  - `-w` releases the assertion if the herdr server exits.
- When no agent works, a one-shot timer waits for the grace period
  (default 60 s), checks again, and then releases the assertion. Work that
  starts during the grace period cancels the release.
- There is no polling loop. Each herdr request has a timeout, so a hung
  server cannot block a hook. If herdr does not answer, the plugin keeps the
  current state. The idle timer releases after 3 failed checks.
- Each herdr session (socket) has its own state, so named sessions do not
  interfere with each other.

The display can still sleep and the screen can still lock.

## Install

```sh
herdr plugin install jewei/herdr-caffeinated
# or, from a local checkout:
herdr plugin link /path/to/herdr-caffeinated
```

The startup hook and event hooks handle state from then on. To check
now without a restart:

```sh
herdr plugin action invoke herdr-caffeinated.start
```

## Actions

| Action                       | Effect                                          |
| ---------------------------- | ----------------------------------------------- |
| `herdr-caffeinated.toggle`   | Pause or resume                                 |
| `herdr-caffeinated.start`    | Resume: stay awake while agents work            |
| `herdr-caffeinated.stop`     | Pause: allow sleep. Stays paused after restart. |
| `herdr-caffeinated.status`   | Show the current state                          |

Bind one to a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "super+shift+c"
type = "plugin_action"
command = "herdr-caffeinated.toggle"
description = "toggle caffeinated"
```

## Configuration

Create `config` in the plugin config directory
(`herdr plugin config-dir herdr-caffeinated`). All keys are optional. The
plugin reads only these keys and ignores values that are not valid. See
`config.example`.

```ini
caffeinate_flags=-ims
idle_grace_seconds=60
awake_statuses=working
request_timeout_seconds=5
notify=1
```

- `caffeinate_flags`: letters from `dimsu`. Add `d` to keep the display on.
- `awake_statuses`: comma list of agent statuses that keep the Mac awake,
  for example `working,blocked`.
- `notify`: `1` shows a herdr toast for action results, `0` is silent.

## Limits

`caffeinate` cannot override every kind of sleep:

- **Lid closed on battery.** macOS sleeps anyway. On AC power with an
  external display (clamshell mode), `-s` keeps the Mac awake.
- **Low battery or thermal events.** macOS can still force sleep.
- **Manual sleep** (Apple menu > Sleep) is not blocked.

To block sleep with the lid closed on battery, you need a system setting
that needs admin rights, for example `sudo pmset -a disablesleep 1`. This
plugin does not change system settings.

## Test

```sh
sh tests/test-plugin.sh
```

The tests use fake `herdr` and `caffeinate` binaries. They do not touch your
real herdr session.

## Logs

- herdr command logs: `herdr plugin log list --plugin herdr-caffeinated`
- plugin log: `$HERDR_PLUGIN_STATE_DIR/session-<hash>/caffeinated.log`
