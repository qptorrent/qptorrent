module main

import gui
import os
import time

fn main() {
	mut app := new_app()

	// Parse CLI arguments for .torrent files
	for i in 1 .. os.args.len {
		arg := os.args[i]
		if arg.ends_with('.torrent') {
			if os.exists(arg) {
				app.pending_paths << os.real_path(arg)
				dbg('CLI arg: queued "${arg}"')
			} else {
				dbg('CLI arg: file not found "${arg}"')
			}
		} else {
			dbg('CLI arg: ignoring "${arg}" (not a .torrent)')
		}
	}

	mut window := gui.window(
		state:    app
		title:    'QPTorrent'
		width:    1000
		height:   600
		on_init:  on_init
		on_event: on_event
	)
	window.set_theme(gui.theme_dark_bordered)
	window.run()
}

fn on_init(mut w gui.Window) {
	mut app := w.state[App]()
	app.window = w

	// Ensure download directory exists
	if !os.exists(app.download_dir) {
		os.mkdir_all(app.download_dir) or {}
	}

	// Load any torrents from CLI arguments
	paths := app.pending_paths.clone()
	app.pending_paths = []string{}
	for path in paths {
		dbg('Loading torrent from CLI: ${path}')
		add_torrent_file(path, mut w)
	}

	// Start periodic speed update timer in background
	spawn speed_timer_loop(mut w)

	w.update_view(main_view)
}

fn speed_timer_loop(mut w &gui.Window) {
	for {
		time.sleep(1 * time.second)
		w.queue_command(fn (mut w gui.Window) {
			update_speeds(mut w)
		})
	}
}

fn on_event(e &gui.Event, mut w gui.Window) {
	if e.typ == .files_dropped {
		paths := w.get_dropped_file_paths()
		for path in paths {
			if path.ends_with('.torrent') {
				dbg('Dropped torrent file: ${path}')
				add_torrent_file(path, mut w)
			}
		}
	}
}

fn update_speeds(mut w gui.Window) {
	mut app := w.state[App]()
	now := time.now()
	elapsed := now - app.last_tick
	secs := f64(elapsed) / f64(time.second)

	if secs > 0 {
		mut total_down := u64(0)
		for mut t in app.torrents {
			if t.state == .downloading {
				bytes_since := if t.downloaded > t.prev_downloaded {
					t.downloaded - t.prev_downloaded
				} else {
					u64(0)
				}
				t.download_speed = u64(f64(bytes_since) / secs)
				t.prev_downloaded = t.downloaded
				total_down += t.download_speed
			} else {
				t.download_speed = 0
			}
		}
		app.total_down = total_down
	}
	app.last_tick = now
}
