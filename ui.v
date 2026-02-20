module main

import gui
import os

fn main_view(mut window gui.Window) gui.View {
	app := window.state[App]()
	if app.show_settings {
		return settings_view(mut window)
	}
	w, h := window.window_size()
	return gui.column(
		width:   w
		height:  h
		sizing:  gui.fixed_fixed
		padding: gui.padding_none
		content: [
			toolbar_view(window),
			torrent_table_view(mut window),
			status_bar_view(window),
		]
	)
}

fn toolbar_view(window &gui.Window) gui.View {
	app := window.state[App]()
	has_selection := app.selected.len > 0

	// Determine if selected torrent is paused or downloading
	mut is_paused := false
	if has_selection {
		for idx, _ in app.selected {
			if idx < app.torrents.len {
				if app.torrents[idx].state == .paused {
					is_paused = true
				}
			}
		}
	}

	return gui.row(
		sizing:  gui.fill_fit
		padding: gui.padding_medium
		spacing: 10
		content: [
			gui.button(
				id_focus: 1
				content:  [gui.text(text: '+ Add Torrent')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					w.native_open_dialog(
						title:          'Select Torrent File'
						start_dir:      os.home_dir()
						allow_multiple: true
						filters:        [
							gui.NativeFileFilter{
								name:       'Torrent Files'
								extensions: ['torrent']
							},
						]
						on_done:        fn (result gui.NativeDialogResult, mut w gui.Window) {
							if result.status == .ok {
								for path in result.paths {
									add_torrent_file(path, mut w)
								}
							}
						}
					)
				}
			),
			gui.button(
				content:  [
					gui.text(text: if is_paused { 'Resume' } else { 'Pause' }),
				]
				disabled: !has_selection
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					toggle_selected(mut w)
					w.update_view(main_view)
				}
			),
			gui.button(
				content:  [gui.text(text: 'Remove')]
				disabled: !has_selection
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					remove_selected(mut w)
					w.update_view(main_view)
				}
			),
			gui.column(sizing: gui.fill_fit),
			gui.button(
				content:  [gui.text(text: 'Settings')]
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					mut a := w.state[App]()
					a.show_settings = true
					w.update_view(main_view)
				}
			),
		]
	)
}

fn torrent_table_view(mut window gui.Window) gui.View {
	app := window.state[App]()

	mut rows := []gui.TableRowCfg{}
	rows << gui.tr([
		gui.th('Name'),
		gui.th('Size'),
		gui.th('Progress'),
		gui.th('Down Speed'),
		gui.th('ETA'),
		gui.th('Peers'),
		gui.th('Seeds'),
		gui.th('Status'),
	])

	for i, t in app.torrents {
		progress := t.progress()
		progress_pct := '${progress * 100.0:.1f}%'
		speed_str := format_speed(t.download_speed)
		eta_str := format_eta(t.remaining(), t.download_speed)
		size_str := format_bytes(t.meta.total_length)
		peers_str := '${t.peers.len}'
		status_str := if t.state == .error {
			'Error: ${t.error_message}'
		} else {
			t.state.str()
		}
		row_idx := i

		rows << gui.TableRowCfg{
			on_click: fn [row_idx] (_ &gui.Layout, mut e gui.Event, mut w gui.Window) {
				mut a := w.state[App]()
				if a.last_click_row == row_idx
					&& a.last_click_frame > 0
					&& e.frame_count - a.last_click_frame <= 24 {
					// Double click - open in file manager
					if row_idx < a.torrents.len {
						open_in_file_manager(a.torrents[row_idx].download_dir)
					}
					a.last_click_row = -1
					a.last_click_frame = 0
				} else {
					a.last_click_row = row_idx
					a.last_click_frame = e.frame_count
				}
			}
			cells: [
				gui.td(t.meta.name),
				gui.td(size_str),
				gui.TableCellCfg{
					content: gui.progress_bar(
						height:  16
						sizing:  gui.fill_fixed
						percent: f32(progress)
						text:    progress_pct
					)
				},
				gui.td(speed_str),
				gui.td(eta_str),
				gui.td(peers_str),
				gui.td('${t.connected_seeds()}'),
				gui.td(status_str),
			]
		}
	}

	// Convert torrent indices (0-based) to table row indices (1-based, header=0)
	mut table_selected := map[int]bool{}
	for idx, _ in app.selected {
		table_selected[idx + 1] = true
	}

	return window.table(
		id:              'torrents'
		id_scroll:       1
		sizing:          gui.fill_fill
		text_style_head: gui.theme().b3
		border_style:    .horizontal
		selected:        table_selected
		on_select:       fn (selected map[int]bool, _ int, mut _ gui.Event, mut w gui.Window) {
			mut a := w.state[App]()
			// Convert table row indices (1-based) to torrent indices (0-based)
			a.selected = map[int]bool{}
			for idx, _ in selected {
				if idx > 0 {
					a.selected[idx - 1] = true
				}
			}
			w.update_view(main_view)
		}
		data:            rows
	)
}

fn status_bar_view(window &gui.Window) gui.View {
	app := window.state[App]()
	count := app.torrents.len
	count_str := '${count} torrent${if count != 1 { 's' } else { '' }}'
	speed_str := 'DL: ${format_speed(app.total_down)}'

	return gui.row(
		sizing:  gui.fill_fit
		padding: gui.padding_small
		content: [
			gui.text(text: '${count_str}  |  ${app.status_message}', text_style: gui.theme().n4),
			gui.column(sizing: gui.fill_fit),
			gui.text(text: speed_str, text_style: gui.theme().n4),
		]
	)
}

// --- Settings view ---

fn settings_view(mut window gui.Window) gui.View {
	app := window.state[App]()
	w, h := window.window_size()

	return gui.column(
		width:   w
		height:  h
		sizing:  gui.fixed_fixed
		padding: gui.padding_none
		content: [
			// Header
			gui.row(
				sizing:  gui.fill_fit
				padding: gui.padding_medium
				spacing: 10
				content: [
					gui.text(text: 'Settings', text_style: gui.theme().b2),
					gui.column(sizing: gui.fill_fit),
					gui.button(
						content:  [gui.text(text: 'Back')]
						on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
							mut a := w.state[App]()
							a.show_settings = false
							db_save_settings(a)
							w.update_view(main_view)
						}
					),
				]
			),
			// Settings body
			gui.column(
				sizing:  gui.fill_fill
				padding: gui.Padding{
					left:   40
					right:  40
					top:    20
					bottom: 20
				}
				spacing: 20
				content: [
					// Download directory
					gui.column(
						sizing:  gui.fill_fit
						spacing: 6
						content: [
							gui.text(text: 'Download Directory', text_style: gui.theme().b3),
							gui.row(
								sizing:  gui.fill_fit
								spacing: 8
								content: [
									gui.input(
										id:       'settings_download_dir'
										id_focus: 10
										text:     app.download_dir
										sizing:   gui.fill_fit
										on_text_commit: fn (_ &gui.Layout, s string, _ gui.InputCommitReason, mut w gui.Window) {
											mut a := w.state[App]()
											a.download_dir = s
										}
									),
									gui.button(
										content:  [gui.text(text: 'Browse')]
										on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
											a := w.state[App]()
											w.native_folder_dialog(
												title:     'Select Download Directory'
												start_dir: a.download_dir
												on_done:   fn (result gui.NativeDialogResult, mut w gui.Window) {
													if result.status == .ok && result.paths.len > 0 {
														mut a := w.state[App]()
														a.download_dir = result.paths[0]
														w.update_view(main_view)
													}
												}
											)
										}
									),
								]
							),
						]
					),
					// Dark mode
					gui.row(
						sizing:  gui.fill_fit
						spacing: 10
						content: [
							gui.switch(
								id:       'settings_dark_mode'
								id_focus: 11
								label:    'Dark Mode'
								select:   app.dark_mode
								on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
									mut a := w.state[App]()
									a.dark_mode = !a.dark_mode
									if a.dark_mode {
										w.set_theme(gui.theme_dark_bordered)
									} else {
										w.set_theme(gui.theme_light_bordered)
									}
									w.update_view(main_view)
								}
							),
						]
					),
					// Sequential download
					gui.row(
						sizing:  gui.fill_fit
						spacing: 10
						content: [
							gui.switch(
								id:       'settings_sequential'
								id_focus: 12
								label:    'Sequential Download'
								select:   app.sequential
								on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
									mut a := w.state[App]()
									a.sequential = !a.sequential
									w.update_view(main_view)
								}
							),
						]
					),
					// Speed limit
					gui.column(
						sizing:  gui.fill_fit
						spacing: 6
						content: [
							gui.text(text: 'Download Speed Limit (KB/s, 0 = unlimited)', text_style: gui.theme().b3),
							gui.numeric_input(
								id:       'settings_speed_limit'
								id_focus: 13
								value:    f64(app.speed_limit_kb)
								min:      0
								max:      1000000
								step_cfg: gui.NumericStepCfg{
									step:         100
									mouse_wheel:  true
									keyboard:     true
									show_buttons: true
								}
								decimals: 0
								sizing:   gui.fill_fit
								on_value_commit: fn (_ &gui.Layout, val ?f64, _ string, mut w gui.Window) {
									mut a := w.state[App]()
									a.speed_limit_kb = int(val or { 0.0 })
								}
							),
						]
					),
				]
			),
		]
	)
}

fn add_torrent_file(path string, mut w gui.Window) {
	dbg('add_torrent_file: ${path}')
	torrent_data := os.read_bytes(path) or {
		dbg('ERROR reading torrent file: ${err.msg()}')
		mut app := w.state[App]()
		app.status_message = 'Error: ${err.msg()}'
		return
	}
	meta := parse_torrent_data(torrent_data) or {
		dbg('ERROR parsing torrent: ${err.msg()}')
		mut app := w.state[App]()
		app.status_message = 'Error: ${err.msg()}'
		return
	}

	mut app := w.state[App]()

	// Dedup check: skip if already loaded (by info_hash)
	for t in app.torrents {
		if t.meta.info_hash == meta.info_hash {
			app.status_message = 'Already added: ${meta.name}'
			return
		}
	}

	download_dir := app.download_dir

	// Initialize pieces
	num_pieces := meta.num_pieces()
	mut pieces := []PieceInfo{cap: num_pieces}
	for i in 0 .. num_pieces {
		pieces << new_piece_info(meta.piece_size(i))
	}

	dbg('Added torrent: "${meta.name}" (${num_pieces} pieces, ${format_bytes(meta.total_length)})')

	torrent := &Torrent{
		meta:         meta
		pieces:       pieces
		state:        .downloading
		download_dir: download_dir
	}
	app.torrents << torrent
	app.status_message = 'Added: ${meta.name}'

	// Save to DB
	db_save_torrent(torrent, torrent_data)

	// Start download in background
	tidx := app.torrents.len - 1
	spawn start_download(tidx, mut w)
}

fn toggle_selected(mut w gui.Window) {
	mut app := w.state[App]()
	for idx, _ in app.selected {
		if idx < app.torrents.len {
			match app.torrents[idx].state {
				.downloading {
					app.torrents[idx].state = .paused
					db_update_state(app.torrents[idx].meta.info_hash, .paused)
				}
				.paused {
					app.torrents[idx].state = .downloading
					db_update_state(app.torrents[idx].meta.info_hash, .downloading)
					tidx := idx
					spawn start_download(tidx, mut w)
				}
				else {}
			}
		}
	}
}

fn open_in_file_manager(path string) {
	$if macos {
		os.execute('open "${path}"')
	} $else $if windows {
		os.execute('explorer "${path}"')
	} $else {
		os.execute('xdg-open "${path}"')
	}
}

fn remove_selected(mut w gui.Window) {
	mut app := w.state[App]()
	// Get indices in reverse order to remove safely
	mut indices := app.selected.keys()
	indices.sort(a > b)
	for idx in indices {
		if idx < app.torrents.len {
			db_remove_torrent(app.torrents[idx].meta.info_hash)
			app.torrents[idx].state = .paused // stop downloads
			app.torrents.delete(idx)
		}
	}
	app.selected = map[int]bool{}
	app.status_message = 'Removed ${indices.len} torrent(s)'
}
