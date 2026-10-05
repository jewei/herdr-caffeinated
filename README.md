# Herdr Caffeinated

A [herdr](https://herdr.dev/) plugin that keeps macOS awake while your agents
work. Lock the screen or walk away: agents keep running. When no agent works,
the Mac can sleep again after a grace period.

## How it works

Herdr runs `bin/caffeinated.sh reconcile` at server startup and on these
events: `pane.agent_status_changed`, `pane.agent_detected`, `pane.exited`,
`pane.closed`, `tab.closed`, `workspace.closed`.

| Agents                  | Process                                           |
| ----------------------- | ------------------------------------------------- |
| at least one `working`  | `/usr/bin/caffeinate -ims -w <server pid>`        |
| none `working`          | `/usr/bin/caffeinate -ims -t 60 -w <server pid>`  |

- `-i` prevents idle system sleep, `-m` prevents disk idle sleep, and `-s`
  prevents system sleep (macOS honors `-s` only on AC power).
- `-t 60` ends the assertion after the grace period. If an agent starts
  work first, the plugin swaps back to the untimed process. Each swap
  starts the new process before it stops the old one, so there is no gap.
- `-w` ends the assertion when the herdr server exits.
- Hooks hold a lock, and each herdr call has a timeout. If herdr does not
  answer, the hook fails and keeps the current state.
- Each herdr session (socket) has its own state. Pause applies to one
  session.

The display can still sleep and the screen can still lock.

## Install

```sh
herdr plugin install jewei/herdr-caffeinated
# or, from a local checkout:
herdr plugin link /path/to/herdr-caffeinated
```

The next agent event activates the plugin. A server restart is not
necessary.

## Actions

| Action                       | Effect                                         |
| ---------------------------- | ---------------------------------------------- |
| `herdr-caffeinated.toggle`   | Pause or resume                                |
| `herdr-caffeinated.pause`    | Allow sleep. Stays paused after a restart.     |
| `herdr-caffeinated.resume`   | Stay awake again while agents work             |
| `herdr-caffeinated.status`   | Print one state line and show a toast          |

`status` prints one stable line, for example:

```text
state=awake pid=43650 server_pid=10698 grace=60 flags=-ims
```

`state` is `awake`, `releasing` (grace period), `idle`, or `paused`.

Bind an action to a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "super+shift+c"
type = "plugin_action"
command = "herdr-caffeinated.toggle"
description = "toggle caffeinated"
```

## Configuration

Create `config` in the directory that
`herdr plugin config-dir herdr-caffeinated` prints. All keys are optional.
The plugin ignores unknown keys and invalid values, and reports them in the
plugin log. See `config.example`.

```ini
caffeinate_flags = -ims
idle_grace_seconds = 60
awake_statuses = working
```

- `caffeinate_flags`: a dash and letters from `dimsu`. Add `d` to keep the
  display on.
- `idle_grace_seconds`: a positive integer.
- `awake_statuses`: a comma list of agent statuses that keep the Mac awake,
  for example `working,blocked`.

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

```sh
herdr plugin log list --plugin herdr-caffeinated
```

Each hook and action records its exit code, stdout, and stderr there. State
files are in `~/.local/state/herdr/plugins/herdr-caffeinated/session-*/`.

## Development

```sh
herdr plugin link .             # use this checkout in herdr
sh tests/test-plugin.sh         # TAP output, about 6 s
bunx shellcheck -s sh bin/*.sh tests/*.sh
```

- The tests use fake `herdr` and `caffeinate` binaries in a temp dir. They
  do not touch a linked copy of the plugin or your real herdr session.
- Test-only environment overrides: `CAFFEINATED_BIN`,
  `CAFFEINATED_SERVER_PID`, `CAFFEINATED_TIMEOUT`.
- The script needs `HERDR_PLUGIN_STATE_DIR`, so run it through herdr:
  `herdr plugin action invoke herdr-caffeinated.status`.
- Do not edit `bin/caffeinated.sh` while hooks run from it: `sh` reads a
  script while it runs it.

## License

[MIT](LICENSE)
