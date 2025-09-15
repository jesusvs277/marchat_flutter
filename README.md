# marchat_flutter

Flutter client for a real‑time chat application.

## Features
- Real‑time messaging over WebSocket
- File send and save support
- Optional end‑to‑end encryption placeholder (key storage only)
- Light, dark, and system themes
- Admin commands (kick, ban, unban, clear DB, stats, backup)

## Requirements
- Flutter 3.32.x
- Dart 3.8.x

## Setup
```
flutter pub get
```

## Run
- Windows:
```
flutter run -d windows
```

## Test
```
flutter test
```

## Build
- Windows:
```
flutter build windows --release
```
- Linux (run on Linux or WSL with toolchain installed):
```
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
flutter config --enable-linux-desktop
flutter build linux --release
```

Artifacts:
- Windows: `build/windows/x64/runner/Release/marchat_flutter.exe`
- Linux: `build/linux/x64/release/bundle/`

## Configuration
- Default server URL: `ws://localhost:8080/ws`
- App entry point: `lib/main.dart`
- Optional secure storage key for global E2E: `MARCHAT_GLOBAL_E2E_KEY`

## Admin Commands
Type into the chat input when connected as admin:
```
:cleardb
:backup
:stats
:kick <user>
:ban <user>
:unban <user>
:allow <user>
:forcedisconnect <user>
```

## Platforms in Source Control
This repository intentionally includes platform directories `android/`, `ios/`, `windows/`, `linux/`, `macos/`, and `web/`. Build outputs and environment‑local files are excluded via `.gitignore`.
