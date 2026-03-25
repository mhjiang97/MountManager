# MountManager

A macOS menu bar app for managing [oxfs](https://github.com/oxfs/oxfs) SSHFS mounts.

## Features

- Mount and unmount remote directories via oxfs from the menu bar
- Reads SSH hosts from `~/.ssh/config` automatically
- Per-host volume management — all hosts visible at once with live mount status
- Configurable mount point template with placeholders (`{host}`, `{user}`, `{hostname}`, `{path}`)
- Password and volume configurations persist across launches (Keychain + UserDefaults)
- Prompts to unmount all volumes on quit

## Install

```bash
brew tap mhjiang97/tap
brew install --cask mount-manager
```

### Dependencies

- [macFUSE](https://macfuse.github.io/) — installed automatically by the cask
- [oxfs](https://github.com/oxfs/oxfs) — installed via `pipx` in post-install

## Build from source

```bash
git clone https://github.com/mhjiang97/MountManager.git
cd MountManager
swiftc -o build/MountManager \
  -parse-as-library \
  -framework SwiftUI \
  -framework Security \
  -framework AppKit \
  MountManager/*.swift
```

## Usage

1. Launch MountManager — it appears as a drive icon in the menu bar
2. Select a host from the dropdown (parsed from `~/.ssh/config`)
3. Enter a remote path (e.g. `/storage5`) and click the add button
4. Click **Mount** to mount, or **Mount All** to mount everything

### Settings

Expand the **Settings** section to configure the mount point template:

| Placeholder  | Description                        | Example           |
|-------------|------------------------------------|--------------------|
| `{host}`    | SSH config host name               | `myserver`         |
| `{user}`    | SSH user                           | `root`             |
| `{hostname}`| Actual hostname or IP              | `192.168.1.100`    |
| `{path}`    | Remote path (slashes stripped)     | `storage5`         |

Default template: `/Volumes/{host}/{path}`

## License

MIT
