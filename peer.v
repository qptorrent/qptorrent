module main

import net
import gui
import encoding.binary

// Peer wire protocol message IDs
const msg_choke = u8(0)
const msg_unchoke = u8(1)
const msg_interested = u8(2)
const msg_not_interested = u8(3)
const msg_have = u8(4)
const msg_bitfield = u8(5)
const msg_request = u8(6)
const msg_piece = u8(7)
const msg_cancel = u8(8)

// Tracks a pending block request
struct PendingRequest {
	piece  int
	offset int
	length int
}

fn start_download(torrent_index int, mut window &gui.Window) {
	app := window.state[App]()
	if torrent_index >= app.torrents.len {
		dbg('start_download: invalid torrent_index ${torrent_index}')
		return
	}
	torrent := app.torrents[torrent_index]

	dbg('--- Starting download: "${torrent.meta.name}" (index=${torrent_index})')

	// Allocate files on disk
	dbg('  Allocating files in ${torrent.download_dir}')
	allocate_files(&torrent.meta, torrent.download_dir) or {
		dbg('  ERROR allocating files: ${err.msg()}')
		window.queue_command(fn [torrent_index, err] (mut w gui.Window) {
			mut a := w.state[App]()
			if torrent_index < a.torrents.len {
				a.torrents[torrent_index].state = .error
				a.torrents[torrent_index].error_message = err.msg()
			}
		})
		return
	}
	dbg('  Files allocated OK')

	// Announce to tracker
	dbg('  Announcing to tracker...')
	resp := tracker_announce(&torrent.meta, app.peer_id, torrent.downloaded, torrent.uploaded,
		torrent.remaining()) or {
		dbg('  ERROR tracker announce: ${err.msg()}')
		window.queue_command(fn [torrent_index, err] (mut w gui.Window) {
			mut a := w.state[App]()
			if torrent_index < a.torrents.len {
				a.torrents[torrent_index].state = .error
				a.torrents[torrent_index].error_message = 'Tracker: ${err.msg()}'
			}
		})
		return
	}

	dbg('  Tracker returned ${resp.peers.len} peers')
	window.queue_command(fn [torrent_index, resp] (mut w gui.Window) {
		mut a := w.state[App]()
		if torrent_index < a.torrents.len {
			a.torrents[torrent_index].seeds = resp.seeders
			a.torrents[torrent_index].leeches = resp.leechers
		}
	})

	// Connect to peers (up to max_peers)
	mut connected := 0
	for addr in resp.peers {
		if connected >= max_peers {
			break
		}
		peer_addr := addr
		dbg('  Spawning peer connection to ${peer_addr}')
		spawn peer_connection(torrent_index, peer_addr, mut window)
		connected++
	}
	dbg('  Spawned ${connected} peer connections')
}

fn peer_connection(torrent_index int, addr string, mut window &gui.Window) {
	// Register peer
	window.queue_command(fn [torrent_index, addr] (mut w gui.Window) {
		mut a := w.state[App]()
		if torrent_index < a.torrents.len {
			a.torrents[torrent_index].peers << PeerInfo{
				addr:      addr
				connected: true
			}
		}
	})

	// Connect
	dbg('  [${addr}] Connecting...')
	mut conn := net.dial_tcp(addr) or {
		dbg('  [${addr}] Connect failed: ${err.msg()}')
		remove_peer(torrent_index, addr, mut window)
		return
	}
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(30_000_000_000) // 30 seconds
	dbg('  [${addr}] Connected')

	// Get info for handshake
	app := window.state[App]()
	if torrent_index >= app.torrents.len {
		return
	}
	info_hash := app.torrents[torrent_index].meta.info_hash.clone()
	peer_id := app.peer_id.clone()

	// Handshake
	dbg('  [${addr}] Sending handshake (info_hash=${hex_str(info_hash[..8])}...)')
	do_handshake(mut conn, info_hash, peer_id) or {
		dbg('  [${addr}] Handshake failed: ${err.msg()}')
		remove_peer(torrent_index, addr, mut window)
		return
	}
	dbg('  [${addr}] Handshake OK')

	// Send interested
	send_message(mut conn, msg_interested, []u8{}) or {
		dbg('  [${addr}] Failed to send interested: ${err.msg()}')
		remove_peer(torrent_index, addr, mut window)
		return
	}
	dbg('  [${addr}] Sent interested')

	// Message loop - local request tracking
	mut peer_bitfield := []bool{}
	mut choked := true
	mut msg_count := 0
	mut pending := []PendingRequest{} // locally tracked in-flight requests

	for {
		// Check if torrent is still active
		a2 := window.state[App]()
		if torrent_index >= a2.torrents.len {
			break
		}
		if a2.torrents[torrent_index].state != .downloading {
			dbg('  [${addr}] Torrent no longer downloading, stopping')
			break
		}

		msg_id, payload := read_message(mut conn) or {
			dbg('  [${addr}] Read error: ${err.msg()}')
			break
		}

		msg_count++

		match msg_id {
			-1 {
				// Keep-alive
				continue
			}
			int(msg_choke) {
				dbg('  [${addr}] Choked')
				choked = true
				pending.clear() // choke invalidates all pending requests
			}
			int(msg_unchoke) {
				dbg('  [${addr}] Unchoked')
				choked = false
				fill_requests(torrent_index, addr, mut conn, peer_bitfield, mut pending, mut
					window)
			}
			int(msg_bitfield) {
				peer_bitfield = parse_bitfield(payload, a2.torrents[torrent_index].meta.num_pieces())
				mut has_count := 0
				for b in peer_bitfield {
					if b {
						has_count++
					}
				}
				dbg('  [${addr}] Bitfield: has ${has_count}/${peer_bitfield.len} pieces')
				window.queue_command(fn [torrent_index, addr, peer_bitfield] (mut w gui.Window) {
					mut a := w.state[App]()
					if torrent_index < a.torrents.len {
						for mut p in a.torrents[torrent_index].peers {
							if p.addr == addr {
								p.bitfield = peer_bitfield.clone()
								break
							}
						}
					}
				})
			}
			int(msg_have) {
				if payload.len >= 4 {
					piece_idx := int(binary.big_endian_u32(payload[0..4]))
					if piece_idx < peer_bitfield.len {
						peer_bitfield[piece_idx] = true
					} else {
						for peer_bitfield.len <= piece_idx {
							peer_bitfield << false
						}
						peer_bitfield[piece_idx] = true
					}
				}
			}
			int(msg_piece) {
				if payload.len >= 8 {
					piece_idx := int(binary.big_endian_u32(payload[0..4]))
					block_off := int(binary.big_endian_u32(payload[4..8]))
					block_data := payload[8..]

					if msg_count <= 5 || msg_count % 200 == 0 {
						dbg('  [${addr}] Piece ${piece_idx} offset=${block_off} len=${block_data.len} (msg #${msg_count})')
					}

					// Remove from pending
					pending = pending.filter(!(it.piece == piece_idx && it.offset == block_off))

					handle_block(torrent_index, piece_idx, block_off, block_data, mut window)

					// Fill pipeline with more requests
					if !choked {
						fill_requests(torrent_index, addr, mut conn, peer_bitfield, mut pending, mut
							window)
					}
				}
			}
			else {
				if msg_count <= 10 {
					dbg('  [${addr}] Unknown msg id=${msg_id} len=${payload.len}')
				}
			}
		}
	}

	dbg('  [${addr}] Disconnected after ${msg_count} messages')
	remove_peer(torrent_index, addr, mut window)
}

// Fill the request pipeline up to max_pipeline, using local tracking to avoid
// re-requesting the same blocks and to avoid reading stale shared state.
fn fill_requests(torrent_index int, addr string, mut conn net.TcpConn, peer_bitfield []bool, mut pending []PendingRequest, mut window &gui.Window) {
	app := window.state[App]()
	if torrent_index >= app.torrents.len {
		return
	}
	torrent := app.torrents[torrent_index]

	for pending.len < max_pipeline {
		// Find a piece and block to request
		piece_idx, block_off, block_len := find_next_block(torrent, peer_bitfield, pending)
		if piece_idx < 0 {
			break
		}

		// Mark piece as downloading on main thread
		window.queue_command(fn [torrent_index, piece_idx] (mut w gui.Window) {
			mut a := w.state[App]()
			if torrent_index < a.torrents.len && piece_idx < a.torrents[torrent_index].pieces.len {
				if a.torrents[torrent_index].pieces[piece_idx].state == .pending {
					a.torrents[torrent_index].pieces[piece_idx].state = .downloading
				}
			}
		})

		// Send request
		send_request(mut conn, piece_idx, block_off, block_len) or {
			dbg('  [${addr}] Failed to send request: ${err.msg()}')
			break
		}

		// Track locally
		pending << PendingRequest{
			piece:  piece_idx
			offset: block_off
			length: block_len
		}
	}
}

// Find the next block to request, considering both the shared torrent state
// AND the locally tracked pending requests to avoid duplicates.
fn find_next_block(torrent &Torrent, peer_bitfield []bool, pending []PendingRequest) (int, int, int) {
	num_pieces := torrent.meta.num_pieces()

	// First: look for blocks in pieces already being downloaded
	for i in 0 .. num_pieces {
		if i >= peer_bitfield.len || !peer_bitfield[i] {
			continue
		}
		if torrent.pieces[i].state != .downloading {
			continue
		}
		piece_size := torrent.meta.piece_size(i)
		num_blocks := (piece_size + block_size - 1) / block_size

		for b in 0 .. num_blocks {
			if torrent.pieces[i].blocks[b] {
				continue // already have it
			}
			offset, length := block_params(piece_size, b)
			// Check not already pending locally
			mut already_pending := false
			for p in pending {
				if p.piece == i && p.offset == offset {
					already_pending = true
					break
				}
			}
			if !already_pending {
				return i, offset, length
			}
		}
	}

	// Second: start a new piece (prefer sequential for all - simpler and works fine)
	for i in 0 .. num_pieces {
		if i >= peer_bitfield.len || !peer_bitfield[i] {
			continue
		}
		if torrent.pieces[i].state != .pending {
			continue
		}
		// Check no pending requests for this piece already (would mean we just picked it)
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
		piece_size := torrent.meta.piece_size(i)
		offset, length := block_params(piece_size, 0)
		return i, offset, length
	}

	return -1, 0, 0
}

fn handle_block(torrent_index int, piece_idx int, block_offset int, data []u8, mut window &gui.Window) {
	block_idx := block_offset / block_size
	data_clone := data.clone()

	window.queue_command(fn [torrent_index, piece_idx, block_idx, block_offset, data_clone] (mut w gui.Window) {
		mut a := w.state[App]()
		if torrent_index >= a.torrents.len {
			return
		}
		mut torrent := a.torrents[torrent_index]
		if piece_idx >= torrent.pieces.len {
			return
		}

		// Write block to disk
		write_block(&torrent.meta, torrent.download_dir, piece_idx, block_offset, data_clone) or {
			dbg('  ERROR writing block: piece=${piece_idx} offset=${block_offset}: ${err.msg()}')
			return
		}

		// Mark block received
		if block_idx < torrent.pieces[piece_idx].blocks.len {
			torrent.pieces[piece_idx].blocks[block_idx] = true
		}
		torrent.pieces[piece_idx].downloaded += data_clone.len
		torrent.downloaded += u64(data_clone.len)

		// Check if piece complete
		if torrent.pieces[piece_idx].is_complete() {
			// Verify piece
			valid := verify_piece(&torrent.meta, torrent.download_dir, piece_idx) or {
				dbg('  ERROR verifying piece ${piece_idx}: ${err.msg()}')
				false
			}
			if valid {
				torrent.pieces[piece_idx].state = .complete
				completed := torrent.completed_pieces()
				total := torrent.meta.num_pieces()
				if completed % 50 == 0 || completed == total {
					dbg('  Piece ${piece_idx} verified OK (${completed}/${total})')
				}
				// Check if all pieces done
				if completed == total {
					torrent.state = .seeding
					a.status_message = '${torrent.meta.name} - Download complete!'
					dbg('  DOWNLOAD COMPLETE: ${torrent.meta.name}')
				}
			} else {
				dbg('  Piece ${piece_idx} FAILED verification, re-downloading')
				torrent.pieces[piece_idx] = new_piece_info(torrent.meta.piece_size(piece_idx))
			}
		}
	})
}

fn do_handshake(mut conn net.TcpConn, info_hash []u8, peer_id []u8) ! {
	mut handshake := []u8{len: 68}
	handshake[0] = 19
	pstr := 'BitTorrent protocol'.bytes()
	for i, b in pstr {
		handshake[1 + i] = b
	}
	for i in 0 .. 20 {
		handshake[28 + i] = info_hash[i]
	}
	for i in 0 .. 20 {
		handshake[48 + i] = peer_id[i]
	}

	conn.write(handshake) or { return error('failed to send handshake: ${err}') }

	mut resp := []u8{len: 68}
	mut total_read := 0
	for total_read < 68 {
		n := conn.read(mut resp[total_read..]) or {
			return error('failed to read handshake: ${err}')
		}
		if n == 0 {
			return error('connection closed during handshake')
		}
		total_read += n
	}

	for i in 0 .. 20 {
		if resp[28 + i] != info_hash[i] {
			return error('info_hash mismatch in handshake')
		}
	}
}

fn send_message(mut conn net.TcpConn, id u8, payload []u8) ! {
	length := 1 + payload.len
	mut msg := []u8{len: 4 + length}
	binary.big_endian_put_u32(mut msg[0..4], u32(length))
	msg[4] = id
	for i, b in payload {
		msg[5 + i] = b
	}
	conn.write(msg) or { return error('failed to send message: ${err}') }
}

fn send_request(mut conn net.TcpConn, piece int, offset int, length int) ! {
	mut payload := []u8{len: 12}
	binary.big_endian_put_u32(mut payload[0..4], u32(piece))
	binary.big_endian_put_u32(mut payload[4..8], u32(offset))
	binary.big_endian_put_u32(mut payload[8..12], u32(length))
	send_message(mut conn, msg_request, payload)!
}

fn read_message(mut conn net.TcpConn) !(int, []u8) {
	mut len_buf := []u8{len: 4}
	read_exact(mut conn, mut len_buf)!
	length := int(binary.big_endian_u32(len_buf[0..4]))

	if length == 0 {
		return -1, []u8{} // keep-alive
	}

	if length > 1024 * 1024 * 16 {
		return error('message too large: ${length} bytes')
	}

	mut body := []u8{len: length}
	read_exact(mut conn, mut body)!

	msg_id := int(body[0])
	payload := if length > 1 { body[1..] } else { []u8{} }
	return msg_id, payload
}

fn read_exact(mut conn net.TcpConn, mut buf []u8) ! {
	mut total := 0
	for total < buf.len {
		n := conn.read(mut buf[total..]) or { return error('read failed: ${err}') }
		if n == 0 {
			return error('connection closed')
		}
		total += n
	}
}

fn parse_bitfield(data []u8, num_pieces int) []bool {
	mut result := []bool{len: num_pieces, init: false}
	for i in 0 .. num_pieces {
		byte_idx := i / 8
		bit_idx := u8(7 - (i % 8))
		if byte_idx < data.len && (data[byte_idx] >> bit_idx) & 1 == 1 {
			result[i] = true
		}
	}
	return result
}

fn remove_peer(torrent_index int, addr string, mut window &gui.Window) {
	window.queue_command(fn [torrent_index, addr] (mut w gui.Window) {
		mut a := w.state[App]()
		if torrent_index < a.torrents.len {
			a.torrents[torrent_index].peers = a.torrents[torrent_index].peers.filter(it.addr != addr)
		}
	})
}
