# Herdr Caffeinated

Herdr Caffeinated is a [Herdr](https://herdr.dev/) plugin for macOS. While a
Herdr agent works, the plugin keeps the Mac awake with `caffeinate`. You can
lock the screen or walk away, and the agent continues. When no agent has
worked for 60 seconds, the Mac can sleep again.

The display still sleeps and the screen still locks on their normal
schedule.

## Install the plugin

To install the plugin from GitHub, run this command:

```sh
herdr plugin install jewei/herdr-caffeinated
```

To use a local checkout instead, run
`herdr plugin link /path/to/herdr-caffeinated`.

You do not need to restart the Herdr server. The plugin starts at the next
agent event.

## Pause the plugin

To let the Mac sleep while agents work, run the `pause` action:

```sh
herdr plugin action invoke herdr-caffeinated.pause
```

The pause stays in effect after a server restart. To end the pause, run the
`resume` action. To see the current state, run the `status` action.

To pause and resume with one key, add a binding to
`~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "super+shift+c"
type = "plugin_action"
command = "herdr-caffeinated.toggle"
description = "toggle caffeinated"
```

## Change the defaults

To change a default, create a file named `config` in the directory that
`herdr plugin config-dir herdr-caffeinated` prints. The file
`config.example` lists every key.

This example keeps the display on. It also keeps the Mac awake while an
agent waits for your input:

```ini
caffeinate_flags = -dims
awake_statuses = working,blocked
```

## Reference

### Actions

Each action applies only to the current Herdr session.

| Action                     | Effect                                                         |
| -------------------------- | -------------------------------------------------------------- |
| `herdr-caffeinated.pause`  | Stops `caffeinate` and lets the Mac sleep. Survives a restart. |
| `herdr-caffeinated.resume` | Ends the pause. Starts `caffeinate` if an agent works.         |
| `herdr-caffeinated.toggle` | Runs `resume` if the session is paused, and `pause` if not.    |
| `herdr-caffeinated.status` | Prints the status line and shows a toast.                      |

### Status line

The `status` action prints one line of `key=value` fields:

```text
state=awake pid=43650 server_pid=10698 grace=60 flags=-ims
```

| Field        | Value                                                     |
| ------------ | --------------------------------------------------------- |
| `state`      | `awake`, `releasing`, `idle`, or `paused`                 |
| `pid`        | The PID of the `caffeinate` process, or `-` if none runs  |
| `server_pid` | The PID of the Herdr server that `caffeinate` waits on    |
| `grace`      | The value of `idle_grace_seconds`                         |
| `flags`      | The `caffeinate` flags in use                             |

| State       | Meaning                                                            |
| ----------- | ------------------------------------------------------------------ |
| `awake`     | An agent works. `caffeinate` runs with no time limit.              |
| `releasing` | No agent works. `caffeinate` exits at the end of the grace period. |
| `idle`      | No `caffeinate` process runs. The Mac can sleep.                   |
| `paused`    | The session is paused. The Mac can sleep.                          |

### Configuration keys

| Key                  | Default   | Valid values                          |
| -------------------- | --------- | ------------------------------------- |
| `caffeinate_flags`   | `-ims`    | A dash and letters from `dimsu`       |
| `idle_grace_seconds` | `60`      | A positive integer                    |
| `awake_statuses`     | `working` | A comma list of lowercase status names |

- `caffeinate_flags` sets the flags that the plugin passes to `caffeinate`.
  The `d` flag keeps the display on.
- `idle_grace_seconds` sets how long the Mac stays awake after the last agent
  stops work.
- `awake_statuses` sets the agent statuses that keep the Mac awake. Herdr
  reports `idle`, `working`, `blocked`, `done`, and `unknown`.

The plugin ignores an unknown key or an invalid value. It writes
`config: ignored <key>=<value>` to the plugin log and uses the default.

### Events

Herdr runs `bin/caffeinated.sh reconcile` at server startup and after each
of these events:

- `pane.agent_status_changed`
- `pane.agent_detected`
- `pane.exited`
- `pane.closed`
- `tab.closed`
- `workspace.closed`

### Logs and exit codes

The command `herdr plugin log list --plugin herdr-caffeinated` shows the
exit code, stdout, and stderr of each hook and action.

| Exit code | Meaning                                                        |
| --------- | -------------------------------------------------------------- |
| `0`       | Success                                                        |
| `1`       | The lock was busy, or `herdr agent list` failed or timed out   |
| `2`       | An unknown command, or a run outside Herdr                     |

The plugin keeps its state files in
`~/.local/state/herdr/plugins/herdr-caffeinated/session-<hash>/`.

## How the plugin keeps the Mac awake

Herdr runs the plugin script after each event in the list above. The script
reads `herdr agent list` and picks one of two `caffeinate` processes.

While at least one agent is `working`, the script runs
`/usr/bin/caffeinate -ims -w <server pid>`. The `-i` flag blocks idle sleep,
and the `-m` flag blocks disk sleep. The `-s` flag blocks system sleep, but
macOS honors it only on AC power.

When no agent works, the script replaces that process with
`/usr/bin/caffeinate -ims -t 60 -w <server pid>`. The `-t 60` flag makes
`caffeinate` exit after 60 seconds with no help from the plugin. If an agent
starts work before then, the script swaps back to the process with no time
limit. Each swap starts the new process before it stops the old one, so the
Mac is never without an assertion between the two.

The `-w` flag ties each process to the Herdr server. When the server exits,
`caffeinate` exits too.

An earlier version ended the grace period with a background timer. If the
timer died, the Mac stayed awake until the server exited. The `-t` flag
moves that job into `caffeinate`, so no plugin process has to stay alive.
The cost is that the plugin does not read the agent list again at the end of
the grace period. The plugin depends on events instead. For this reason it
listens for `tab.closed` and `workspace.closed`, because Herdr sends no
`pane.closed` event for the panes in a closed tab or workspace.

Hooks can run at the same time. Each hook takes a lock on a file in the
session state directory before it reads or changes state. The kernel
releases the lock when the hook exits, so a hook that crashes cannot leave a
stale lock. Each `herdr` call has a 5-second timeout. If Herdr does not
answer, the hook keeps the current state and exits with code 1.

Each Herdr session has its own socket, its own server, and its own state
directory. A pause in one session does not affect another session.

## What caffeinate cannot block

`caffeinate` holds a power assertion, and macOS ignores power assertions in
these cases:

- **Lid closed on battery.** The Mac sleeps. On AC power with an external
  display, the `-s` flag keeps the Mac awake in clamshell mode.
- **Low battery or high temperature.** macOS can force sleep.
- **Manual sleep.** The **Sleep** item in the Apple menu still works.

The plugin does not change system settings. To block sleep with the lid
closed on battery, you need an admin setting such as
`sudo pmset -a disablesleep 1`.

## Develop the plugin

1. To use your checkout in Herdr, run `herdr plugin link .` from the repo
   root.
2. To run the tests, run `sh tests/test-plugin.sh`.
3. To run the linter, run `bunx shellcheck -s sh bin/*.sh tests/*.sh`.

The tests print TAP output and take about 6 seconds. They run a copy of the
plugin in a temporary directory with fake `herdr` and `caffeinate` programs.
The tests never touch a linked copy of the plugin or your Herdr session.

The script reads three environment variables that exist only for tests:
`CAFFEINATED_BIN`, `CAFFEINATED_SERVER_PID`, and `CAFFEINATED_TIMEOUT`.

If you edit `bin/caffeinated.sh` while a hook runs from it, the hook can
fail. `sh` reads a script while it runs it.

The script needs the `HERDR_PLUGIN_STATE_DIR` variable that Herdr sets. If
you run it outside Herdr, it exits with code 2. To run an action by hand,
use `herdr plugin action invoke`.

## License

The plugin uses the [MIT license](LICENSE).
