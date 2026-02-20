module main

import gui
import os

fn main_view(mut window gui.Window) gui.View {
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
				}
			),
			gui.button(
				content:  [gui.text(text: 'Remove')]
				disabled: !has_selection
				on_click: fn (_ &gui.Layout, mut _ gui.Event, mut w gui.Window) {
					remove_selected(mut w)
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
		gui.th('Seeds'),
		gui.th('Status'),
	])

	for t in app.torrents {
		progress := t.progress()
		progress_pct := '${progress * 100.0:.1f}%'
		speed_str := format_speed(t.download_speed)
		eta_str := format_eta(t.remaining(), t.download_speed)
		size_str := format_bytes(t.meta.total_length)
		status_str := if t.state == .error {
			'Error: ${t.error_message}'
		} else {
			t.state.str()
		}

		rows << gui.tr([
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
			gui.td('${t.seeds}'),
			gui.td(status_str),
		])
	}

	return window.table(
		id:              'torrents'
		id_scroll:       1
		sizing:          gui.fill_fill
		text_style_head: gui.theme().b3
		border_style:    .horizontal
		selected:        app.selected
		on_select:       fn (selected map[int]bool, _ int, mut _ gui.Event, mut w gui.Window) {
			mut a := w.state[App]()
			a.selected = selected.clone()
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

fn add_torrent_file(path string, mut w gui.Window) {
	meta := parse_torrent_file(path) or {
		mut app := w.state[App]()
		app.status_message = 'Error: ${err.msg()}'
		return
	}

	mut app := w.state[App]()
	download_dir := app.download_dir

	// Initialize pieces
	num_pieces := meta.num_pieces()
	mut pieces := []PieceInfo{cap: num_pieces}
	for i in 0 .. num_pieces {
		pieces << new_piece_info(meta.piece_size(i))
	}

	torrent := &Torrent{
		meta:         meta
		pieces:       pieces
		state:        .downloading
		download_dir: download_dir
	}
	app.torrents << torrent
	app.status_message = 'Added: ${meta.name}'

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
				}
				.paused {
					app.torrents[idx].state = .downloading
					tidx := idx
					spawn start_download(tidx, mut w)
				}
				else {}
			}
		}
	}
}

fn remove_selected(mut w gui.Window) {
	mut app := w.state[App]()
	// Get indices in reverse order to remove safely
	mut indices := app.selected.keys()
	indices.sort(a > b)
	for idx in indices {
		if idx < app.torrents.len {
			app.torrents[idx].state = .paused // stop downloads
			app.torrents.delete(idx)
		}
	}
	app.selected = map[int]bool{}
	app.status_message = 'Removed ${indices.len} torrent(s)'
}
