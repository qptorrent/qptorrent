# qpTorrent

A BitTorrent client written in [V](https://vlang.io) with a native GUI built on [vlang/gui](https://github.com/vlang/gui).

![CI](https://github.com/qptorrent/qptorrent/actions/workflows/ci.yml/badge.svg)

<img width="1112" height="744" alt="image" src="https://github.com/user-attachments/assets/c9b12151-e1a7-485e-a811-11ed71753f87" />


## Features

- Native GUI with dark/light themes
- Drag-and-drop `.torrent` files onto the window
- Headless CLI mode for downloading without a GUI
- Pause, resume, and remove torrents
- Resumes partial downloads across restarts (verifies pieces on disk)
- Concurrent peer connections with pipelined block requests
- Multi-file and single-file torrent support
- HTTP tracker announce with announce-list fallback
- Configurable download directory, speed limit, and sequential mode
- SQLite database for persistent torrent state and settings
- Double-click a torrent row to open its folder in the file manager

## Usage

### GUI mode

```
./qptorrent
```

Opens the main window. Add torrents with the toolbar button, the native file dialog, or by dragging `.torrent` files onto the window.

### CLI mode

```
./qptorrent file.torrent [file2.torrent ...]
```

Downloads directly in the terminal with a progress bar. Pass `-v` or `--verbose` for debug logging.

Downloads go to `~/Downloads/torrents/` by default (configurable in Settings).

## Building

Requires the [V compiler](https://vlang.io).

```
v install gui
v .
```

Production build:

```
v -prod .
```

### System dependencies

The GUI depends on [vglyph](https://github.com/vlang/vglyph) for text rendering, which needs native libraries:

**macOS**
```
brew install pango harfbuzz freetype2
```

**Linux (Debian/Ubuntu)**
```
sudo apt install libpango1.0-dev libfontconfig1-dev libfribidi-dev libharfbuzz-dev libfreetype-dev libgl1-mesa-dri libxcursor-dev libxi-dev libxrandr-dev freeglut3-dev libdbus-1-dev
```

**Windows**
```
vcpkg install pango freetype
```

## Architecture

The project is ~2500 lines of V across 12 source files, all in `module main`.

```
main.v      Entry point, window setup, event loop, speed timer
state.v     Data types: App, Torrent, PieceInfo, PeerInfo, TorrentMetainfo
ui.v        GUI views: toolbar, torrent table, status bar, settings panel
torrent.v   .torrent file parser (bencode -> TorrentMetainfo)
bencode.v   Bencode decoder/encoder and raw info dict extraction for hashing
tracker.v   HTTP tracker announce and response parsing (compact + dict peers)
peer.v      Peer wire protocol: handshake, message loop, pipelined block requests
piece.v     Piece verification (SHA1) and block offset calculation
disk.v      File allocation, block read/write across multi-file boundaries
db.v        SQLite persistence for torrents and settings
cli.v       Headless CLI download mode with channel-based block dispatch
util.v      Formatting helpers, URL encoding, peer ID generation, debug logging
```

### Download pipeline

1. **Parse** the `.torrent` file: decode bencode, extract metainfo, compute SHA1 info hash
2. **Announce** to HTTP trackers (primary + announce-list fallback) to get a peer list
3. **Connect** to up to 15 peers concurrently, each in its own `spawn`ed coroutine
4. Each peer performs the **BitTorrent handshake**, sends `interested`, then enters a message loop
5. On `unchoke`, the peer **pipelines** up to 5 block requests (16 KB each), preferring pieces already in progress (sequential order)
6. Received blocks are **written to disk** immediately, spanning file boundaries for multi-file torrents
7. When all blocks of a piece arrive, it's **SHA1-verified** against the expected hash; failed pieces are re-queued
8. A 1-second timer on the main thread **polls download speeds** and refreshes the UI
9. Torrent state is **persisted to SQLite** so partial downloads survive restarts

### GUI architecture

The GUI uses an immediate-mode-style pattern via `vlang/gui`:

- `App` struct holds all state (torrent list, settings, selection)
- `main_view` returns the full view tree each frame: toolbar, table, status bar
- User actions (button clicks, file drops) mutate `App` state then call `window.update_view`
- Background peer coroutines send updates to the main thread via `window.queue_command`
- The torrent table supports row selection, double-click to open folder, and progress bars

### CLI architecture

CLI mode uses V channels instead of the GUI event loop:

- Each peer coroutine sends `BlockResult` messages to a shared channel
- The main thread receives blocks, writes to disk, and updates a shared `CliState`
- A separate coroutine prints a progress bar to stderr every second

## License

GPL2
