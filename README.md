# MountManager

A macOS menu bar app for managing [oxfs](https://github.com/oxfs/oxfs) SSHFS mounts.

## Features

- Mount and unmount remote directories via oxfs from the menu bar
- Reads SSH hosts from `~/.ssh/config` automatically
- Per-host volume management with live mount status
- macOS Tahoe Liquid Glass UI
- **Open in Finder** — click a mounted volume to reveal it
- **Connection status** — automatic SSH latency checks every 2 minutes with colored indicators
- **Notifications** — macOS notifications on mount failure or unexpected disconnect
- **Favorites** — star volumes for one-click batch mounting
- **Log viewer** — view oxfs logs directly from the app
- **Search/filter** — filter hosts and volumes when the list gets long
- **Right-click context menu** — mount, unmount, open, copy path, view log, favorite
- **Reorder** — rearrange hosts and volumes with up/down arrows on hover
- **Menu bar badge** — mounted volume count shown next to the icon
- **Animated icon** — menu bar icon pulses while mounting is in progress
- **Appearance** — auto, light, or dark mode
- Configurable mount point template (`{host}`, `{user}`, `{hostname}`, `{path}`)
- Password stored in Keychain, volume config in UserDefaults

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
APP=build/MountManager.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MountManager/Info.plist "$APP/Contents/"
swiftc -o "$APP/Contents/MacOS/MountManager" \
  -sdk $(xcrun --show-sdk-path) \
  -framework SwiftUI \
  -framework Security \
  -framework AppKit \
  -framework UserNotifications \
  MountManager/*.swift
```

## Usage

1. Launch MountManager — it appears as a drive icon in the menu bar
2. Click **Add Volume**, select a host (parsed from `~/.ssh/config`)
3. Enter a remote path (e.g. `/storage5`) and click **Add**
4. Click the bolt icon to mount, or use **Mount All** for everything
5. Right-click any volume for more actions (open in Finder, copy path, view log, favorite)
6. Star your most-used volumes and use **Mount Favorites** to mount them all at once

### Settings

Click the gear icon in the footer to configure:

| Placeholder  | Description                    | Example         |
| ------------ | ------------------------------ | --------------- |
| `{host}`     | SSH config host name           | `myserver`      |
| `{user}`     | SSH user                       | `root`          |
| `{hostname}` | Actual hostname or IP          | `192.168.1.100` |
| `{path}`     | Remote path (slashes stripped) | `storage5`      |

Default template: `/Volumes/{host}/{path}`

## License

[MIT](LICENSE)
