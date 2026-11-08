# Audio Inhibit Zig

## Description

Prevents idle/sleep while any application is playing/capturing audio through PipeWire.

Depends on:
- PipeWire to detect media playback/recording.
- systemd/elogind to issue idle inhibit requests via calls to `org.freedesktop.login1.Manager.Inhibit` through D-Bus.

## Usage

### Basic usage

The basic usage connects to the system D-Bus and prevents idle while media is playing:

```bash
audio_inhibit_zig
```

### Dry run
Dry run shows current active nodes and what idle lock would be active without preventing idle.

```bash
audio_inhibit_zig --dry-run
```

### Waybar support
To display what idle lock is currently active, add to any waybar config:

```
"custom/audio_inhibit": {
  "format": "{icon}",
  "exec": "audio_inhibit_zig --waybar",
  "exec-if": "which audio_inhibit_zig",
  "return-type": "json",
  "format-icons": {
    "sleep": "",
    "idle": "",
    "none": ""
  }
}
```

## Config
Config files may be explicitly specified using `--config <path>`, otherwise it will default to `${XDG_CONFIG_HOME}/audio_inhibit_zig/config.json`. Config files look something like this:

```json
{
    "sleep_conditions": {
        "application_names": [
            "Spotify",
            "Discord"
        ],
        "media_types": [
            "Audio"
        ],
        "media_categories": [
            "Playback"
        ],
        "media_roles": [
            "Music"
        ]
    }
}
```

`sleep_conditions` use PipeWire node props to change the idle behavior of a node. If any of the props match the prop values for a specific prop, then that node will marked as requesting a `sleep` inhibitor lock instead of an `idle`. Once all nodes are accounted for, then `audio_inhibit_zig` will send a Inhibit request with a `sleep` inhibitor lock if all nodes currently active request a `sleep`. However if at least one node requests an `idle`, then `audio_inhibit_zig` will send an `idle` request instead.

This can be used, for example, if music is playing and you would like to allow the monitor to shut off but prevent the system from suspending, in this case, `idle` would not allow the monitor to shut off, so a `sleep` lock would be more appropriate. You can register the application name in the `application_names` array so when audio plays from that application the monitor is still able to shut off.

Currently supported PipeWire props are `application_names`, `media_types`, `media_categories` and `media_roles`.
