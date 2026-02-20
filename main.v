module main

import gui
import os
import time

fn main() {
	mut window := gui.window(
		state:    new_app()
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
