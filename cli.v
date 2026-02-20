module main

import encoding.binary
import net
import os
import time

@[heap]
struct CliState {
mut:
	meta         &TorrentMetainfo
	pieces       []PieceInfo
	download_dir string
	downloaded   u64
	completed    int
	done         bool
}

struct BlockResult {
	piece     int
	offset    int
	data      []u8
	peer_done bool // true = peer disconnected signal
}

fn cli_download(torrent_path string) {
	torrent_data := os.read_bytes(torrent_path) or {
		eprintln('Error reading file: ${err.msg()}')
		return
	}
	meta := parse_torrent_data(torrent_data) or {
		eprintln('Error: ${err.msg()}')
		return
	}

	download_dir := default_download_dir()
	if !os.exists(download_dir) {
		os.mkdir_all(download_dir) or {}
	}
	peer_id := generate_peer_id()

	allocate_files(&meta, download_dir) or {
		eprintln('Error allocating files: ${err.msg()}')
		return
	}

	// Save to DB so GUI can pick it up
	cli_torrent := &Torrent{
		meta:         meta
		state:        .downloading
		download_dir: download_dir
	}
	db_save_torrent(cli_torrent, torrent_data)

	num_pieces := meta.num_pieces()
	mut pieces := []PieceInfo{cap: num_pieces}
	for i in 0 .. num_pieces {
		pieces << new_piece_info(meta.piece_size(i))
	}

	// Verify existing pieces on disk to resume partial downloads
	mut initial_downloaded := u64(0)
	mut initial_completed := 0
	for i in 0 .. num_pieces {
		valid := verify_piece(&meta, download_dir, i) or { false }
		if valid {
			pieces[i].state = .complete
			piece_sz := meta.piece_size(i)
			pieces[i].downloaded = piece_sz
			for b in 0 .. pieces[i].blocks.len {
				pieces[i].blocks[b] = true
			}
			initial_downloaded += u64(piece_sz)
			initial_completed++
		}
	}

	if initial_completed > 0 {
		eprintln('Resumed: ${initial_completed}/${num_pieces} pieces already verified on disk')
	}

	if initial_completed == num_pieces {
		eprintln('Download already complete: ${os.join_path(download_dir, meta.name)}')
		return
	}

	left := meta.total_length - initial_downloaded
	resp := tracker_announce(&meta, peer_id, initial_downloaded, 0, left) or {
		eprintln('Tracker error: ${err.msg()}')
		return
	}

	eprintln('${meta.name} | ${format_bytes(meta.total_length)} | ${num_pieces} pieces')
	eprintln('${resp.peers.len} peers found')

	mut state := &CliState{
		meta:         &meta
		pieces:       pieces
		download_dir: download_dir
		downloaded:   initial_downloaded
		completed:    initial_completed
	}

	ch := chan BlockResult{cap: 128}

	mut connected := 0
	for addr in resp.peers {
		if connected >= max_peers {
			break
		}
		spawn cli_peer_connection(addr, &meta, peer_id, state, ch)
		connected++
	}

	// Progress printer
	spawn cli_progress(state, &meta)

	// Main loop: receive blocks, update state
	mut active_peers := connected
	for state.completed < num_pieces && active_peers > 0 {
		block := <-ch

		if block.peer_done {
			active_peers--
			continue
		}

		piece_idx := block.piece
		block_offset := block.offset
		block_idx := block_offset / block_size

		// Skip duplicates
		if piece_idx >= state.pieces.len {
			continue
		}
		if state.pieces[piece_idx].state == .complete {
			continue
		}
		if block_idx < state.pieces[piece_idx].blocks.len
			&& state.pieces[piece_idx].blocks[block_idx] {
			continue
		}

		// Write to disk
		write_block(&meta, download_dir, piece_idx, block_offset, block.data) or {
			dbg('Write error: ${err.msg()}')
			continue
		}

		// Update state
		if block_idx < state.pieces[piece_idx].blocks.len {
			state.pieces[piece_idx].blocks[block_idx] = true
		}
		state.pieces[piece_idx].downloaded += block.data.len
		state.downloaded += u64(block.data.len)

		// Mark as downloading if still pending
		if state.pieces[piece_idx].state == .pending {
			state.pieces[piece_idx].state = .downloading
		}

		// Check piece completion
		if state.pieces[piece_idx].is_complete() {
			valid := verify_piece(&meta, download_dir, piece_idx) or { false }
			if valid {
				state.pieces[piece_idx].state = .complete
				state.completed++
			} else {
				dbg('Piece ${piece_idx} FAILED verification, re-downloading')
				state.pieces[piece_idx] = new_piece_info(meta.piece_size(piece_idx))
			}
		}
	}

	state.done = true
	// Clear progress line and print result
	eprint('\r' + ' '.repeat(80) + '\r')
	if state.completed == num_pieces {
		db_update_state(meta.info_hash, .seeding)
		eprintln('Download complete: ${os.join_path(download_dir, meta.name)}')
	} else {
		db_update_state(meta.info_hash, .paused)
		eprintln('Download stopped (${state.completed}/${num_pieces} pieces, all peers disconnected)')
	}
}

fn cli_progress(state &CliState, meta &TorrentMetainfo) {
	num_pieces := meta.num_pieces()
	mut prev_downloaded := u64(0)
	mut last_time := time.now()

	for !state.done {
		time.sleep(1 * time.second)
		if state.done {
			break
		}

		now := time.now()
		elapsed := f64(now - last_time) / f64(time.second)
		speed := if elapsed > 0 {
			u64(f64(state.downloaded - prev_downloaded) / elapsed)
		} else {
			u64(0)
		}
		remaining := if meta.total_length > state.downloaded {
			meta.total_length - state.downloaded
		} else {
			u64(0)
		}
		pct := f64(state.downloaded) * 100.0 / f64(meta.total_length)
		eta := format_eta(remaining, speed)

		bar_width := 30
		filled := int(pct * f64(bar_width) / 100.0)
		mut bar := []u8{cap: bar_width}
		for _ in 0 .. filled {
			bar << `#`
		}
		for _ in filled .. bar_width {
			bar << `-`
		}

		eprint('\r[${bar.bytestr()}] ${pct:.1f}% ${format_bytes(state.downloaded)}/${format_bytes(meta.total_length)} ${format_speed(speed)} ETA:${eta} ${state.completed}/${num_pieces}pcs  ')

		prev_downloaded = state.downloaded
		last_time = now
	}
}

fn cli_peer_connection(addr string, meta &TorrentMetainfo, peer_id []u8, state &CliState, ch chan BlockResult) {
	defer {
		ch <- BlockResult{
			peer_done: true
		}
	}

	dbg('[${addr}] Connecting...')
	mut conn := net.dial_tcp(addr) or {
		dbg('[${addr}] Connect failed: ${err.msg()}')
		return
	}
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(30_000_000_000)

	do_handshake(mut conn, meta.info_hash, peer_id) or {
		dbg('[${addr}] Handshake failed: ${err.msg()}')
		return
	}

	send_message(mut conn, msg_interested, []u8{}) or {
		dbg('[${addr}] Send interested failed: ${err.msg()}')
		return
	}

	mut peer_bitfield := []bool{}
	mut choked := true
	mut pending := []PendingRequest{}

	for !state.done {
		msg_id, payload := read_message(mut conn) or {
			dbg('[${addr}] Read error: ${err.msg()}')
			break
		}

		match msg_id {
			-1 {
				continue
			}
			int(msg_choke) {
				choked = true
				pending.clear()
			}
			int(msg_unchoke) {
				choked = false
				cli_fill_requests(addr, meta, state, mut conn, peer_bitfield, mut pending)
			}
			int(msg_bitfield) {
				peer_bitfield = parse_bitfield(payload, meta.num_pieces())
			}
			int(msg_have) {
				if payload.len >= 4 {
					idx := int(binary.big_endian_u32(payload[0..4]))
					for peer_bitfield.len <= idx {
						peer_bitfield << false
					}
					peer_bitfield[idx] = true
				}
			}
			int(msg_piece) {
				if payload.len >= 8 {
					piece_idx := int(binary.big_endian_u32(payload[0..4]))
					block_off := int(binary.big_endian_u32(payload[4..8]))
					block_data := payload[8..]

					pending = pending.filter(!(it.piece == piece_idx && it.offset == block_off))

					ch <- BlockResult{
						piece:  piece_idx
						offset: block_off
						data:   block_data.clone()
					}

					if !choked {
						cli_fill_requests(addr, meta, state, mut conn, peer_bitfield, mut
							pending)
					}
				}
			}
			else {}
		}
	}
	dbg('[${addr}] Disconnected')
}

fn cli_fill_requests(addr string, meta &TorrentMetainfo, state &CliState, mut conn net.TcpConn, peer_bitfield []bool, mut pending []PendingRequest) {
	for pending.len < max_pipeline {
		piece_idx, block_off, block_len := cli_find_next_block(meta, state, peer_bitfield,
			pending)
		if piece_idx < 0 {
			break
		}

		send_request(mut conn, piece_idx, block_off, block_len) or {
			dbg('[${addr}] Send request failed: ${err.msg()}')
			break
		}

		pending << PendingRequest{
			piece:  piece_idx
			offset: block_off
			length: block_len
		}
	}
}

fn cli_find_next_block(meta &TorrentMetainfo, state &CliState, peer_bitfield []bool, pending []PendingRequest) (int, int, int) {
	num_pieces := meta.num_pieces()

	// First: blocks in pieces already downloading
	for i in 0 .. num_pieces {
		if i >= peer_bitfield.len || !peer_bitfield[i] {
			continue
		}
		if state.pieces[i].state != .downloading {
			continue
		}
		piece_size := meta.piece_size(i)
		num_blocks := (piece_size + block_size - 1) / block_size

		for b in 0 .. num_blocks {
			if state.pieces[i].blocks[b] {
				continue
			}
			offset, length := block_params(piece_size, b)
			mut already := false
			for p in pending {
				if p.piece == i && p.offset == offset {
					already = true
					break
				}
			}
			if !already {
				return i, offset, length
			}
		}
	}

	// Second: start a new piece (sequential order)
	for i in 0 .. num_pieces {
		if i >= peer_bitfield.len || !peer_bitfield[i] {
			continue
		}
		if state.pieces[i].state != .pending {
			continue
		}
		mut has_pending := false
		for p in pending {
			if p.piece == i {
				has_pending = true
				break
			}
		}
		if has_pending {
			continue
		}
		piece_size := meta.piece_size(i)
		offset, length := block_params(piece_size, 0)
		return i, offset, length
	}

	return -1, 0, 0
}
