module main

import db.sqlite
import os

@[table: 'torrents']
struct TorrentRow {
	id            int @[primary; sql: serial]
	info_hash_hex string
	torrent_hex   string // raw .torrent bytes as hex
	download_dir  string
	state         int // TorrentState as int
}

@[table: 'settings']
struct SettingsRow {
	id             int @[primary; sql: serial]
	download_dir   string
	dark_mode      int
	sequential     int
	speed_limit_kb int
}

fn open_db() !sqlite.DB {
	dir := os.join_path(os.home_dir(), '.qptorrent')
	if !os.exists(dir) {
		os.mkdir_all(dir) or { return error('failed to create ${dir}: ${err}') }
	}
	db_path := os.join_path(dir, 'torrents.db')
	mut db := sqlite.connect(db_path)!
	sql db {
		create table TorrentRow
	}!
	sql db {
		create table SettingsRow
	}!
	return db
}

fn db_save_torrent(torrent &Torrent, torrent_data []u8) {
	mut db := open_db() or {
		dbg('db_save_torrent: open_db failed: ${err.msg()}')
		return
	}
	defer {
		db.close() or {}
	}
	ih := hex_str(torrent.meta.info_hash)
	// Check if already exists
	existing := sql db {
		select from TorrentRow where info_hash_hex == ih
	} or { []TorrentRow{} }
	if existing.len > 0 {
		dbg('db_save_torrent: already exists: ${ih}')
		return
	}
	row := TorrentRow{
		info_hash_hex: ih
		torrent_hex:   hex_str(torrent_data)
		download_dir:  torrent.download_dir
		state:         int(torrent.state)
	}
	sql db {
		insert row into TorrentRow
	} or { dbg('db_save_torrent: insert failed: ${err.msg()}') }
}

fn db_update_state(info_hash []u8, state TorrentState) {
	mut db := open_db() or {
		dbg('db_update_state: open_db failed: ${err.msg()}')
		return
	}
	defer {
		db.close() or {}
	}
	ih := hex_str(info_hash)
	s := int(state)
	sql db {
		update TorrentRow set state = s where info_hash_hex == ih
	} or { dbg('db_update_state: update failed: ${err.msg()}') }
}

fn db_remove_torrent(info_hash []u8) {
	mut db := open_db() or {
		dbg('db_remove_torrent: open_db failed: ${err.msg()}')
		return
	}
	defer {
		db.close() or {}
	}
	ih := hex_str(info_hash)
	sql db {
		delete from TorrentRow where info_hash_hex == ih
	} or { dbg('db_remove_torrent: delete failed: ${err.msg()}') }
}

fn db_load_all() ![]TorrentRow {
	mut db := open_db()!
	defer {
		db.close() or {}
	}
	rows := sql db {
		select from TorrentRow
	}!
	return rows
}

fn restore_torrents(mut app App) {
	rows := db_load_all() or {
		dbg('restore_torrents: ${err.msg()}')
		return
	}
	dbg('restore_torrents: ${rows.len} row(s) in DB')
	for row in rows {
		torrent_bytes := hex_to_bytes(row.torrent_hex)
		meta := parse_torrent_data(torrent_bytes) or {
			dbg('restore_torrents: failed to parse torrent ${row.info_hash_hex}: ${err.msg()}')
			continue
		}

		num_pieces := meta.num_pieces()
		mut pieces := []PieceInfo{cap: num_pieces}
		for i in 0 .. num_pieces {
			pieces << new_piece_info(meta.piece_size(i))
		}

		// Verify existing pieces from disk
		mut downloaded := u64(0)
		mut completed := 0
		for i in 0 .. num_pieces {
			valid := verify_piece(&meta, row.download_dir, i) or { false }
			if valid {
				pieces[i].state = .complete
				piece_sz := meta.piece_size(i)
				pieces[i].downloaded = piece_sz
				// Mark all blocks as received
				for b in 0 .. pieces[i].blocks.len {
					pieces[i].blocks[b] = true
				}
				downloaded += u64(piece_sz)
				completed++
			}
		}

		// Determine state
		state := if completed == num_pieces {
			TorrentState.seeding
		} else {
			TorrentState.paused
		}

		dbg('restore_torrents: "${meta.name}" ${completed}/${num_pieces} pieces, state=${state}')

		torrent := &Torrent{
			meta:         meta
			pieces:       pieces
			state:        state
			downloaded:   downloaded
			download_dir: row.download_dir
		}
		app.torrents << torrent
	}
	if rows.len > 0 {
		app.status_message = 'Restored ${rows.len} torrent(s)'
	}
}

fn hex_to_bytes(hex string) []u8 {
	if hex.len % 2 != 0 {
		return []u8{}
	}
	mut result := []u8{cap: hex.len / 2}
	for i := 0; i < hex.len; i += 2 {
		hi := hex_nibble(hex[i])
		lo := hex_nibble(hex[i + 1])
		result << (hi << 4) | lo
	}
	return result
}

fn hex_nibble(c u8) u8 {
	if c >= `0` && c <= `9` {
		return c - `0`
	} else if c >= `A` && c <= `F` {
		return c - `A` + 10
	} else if c >= `a` && c <= `f` {
		return c - `a` + 10
	}
	return 0
}

fn db_load_settings(mut app App) {
	mut db := open_db() or {
		dbg('db_load_settings: ${err.msg()}')
		return
	}
	defer {
		db.close() or {}
	}
	rows := sql db {
		select from SettingsRow limit 1
	} or { return }
	if rows.len > 0 {
		s := rows[0]
		app.download_dir = s.download_dir
		app.dark_mode = s.dark_mode != 0
		app.sequential = s.sequential != 0
		app.speed_limit_kb = s.speed_limit_kb
	}
}

fn db_save_settings(app &App) {
	mut db := open_db() or {
		dbg('db_save_settings: ${err.msg()}')
		return
	}
	defer {
		db.close() or {}
	}
	// Delete all existing settings
	sql db {
		delete from SettingsRow where id > 0
	} or {}
	// Also delete id=0 row
	sql db {
		delete from SettingsRow where id == 0
	} or {}
	row := SettingsRow{
		download_dir:   app.download_dir
		dark_mode:      if app.dark_mode { 1 } else { 0 }
		sequential:     if app.sequential { 1 } else { 0 }
		speed_limit_kb: app.speed_limit_kb
	}
	sql db {
		insert row into SettingsRow
	} or { dbg('db_save_settings: insert failed: ${err.msg()}') }
}
