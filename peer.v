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

fn start_download(torrent_index int, mut window &gui.Window) {
	app := window.state[App]()
	torrent := app.torrents[torrent_index]

	// Allocate files on disk
	allocate_files(&torrent.meta, torrent.download_dir) or {
		window.queue_command(fn [torrent_index, err] (mut w gui.Window) {
			mut a := w.state[App]()
			if torrent_index < a.torrents.len {
				a.torrents[torrent_index].state = .error
				a.torrents[torrent_index].error_message = err.msg()
			}
		})
		return
	}

	// Announce to tracker
	resp := tracker_announce(&torrent.meta, app.peer_id, torrent.downloaded, torrent.uploaded,
		torrent.remaining()) or {
		window.queue_command(fn [torrent_index, err] (mut w gui.Window) {
			mut a := w.state[App]()
			if torrent_index < a.torrents.len {
				a.torrents[torrent_index].state = .error
				a.torrents[torrent_index].error_message = 'Tracker: ${err.msg()}'
			}
		})
		return
	}

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
		spawn peer_connection(torrent_index, peer_addr, mut window)
		connected++
	}
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
	mut conn := net.dial_tcp(addr) or {
		remove_peer(torrent_index, addr, mut window)
		return
	}
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(30_000_000_000) // 30 seconds

	// Get info for handshake
	app := window.state[App]()
	if torrent_index >= app.torrents.len {
		return
	}
	info_hash := app.torrents[torrent_index].meta.info_hash.clone()
	peer_id := app.peer_id.clone()

	// Handshake
	do_handshake(mut conn, info_hash, peer_id) or {
		remove_peer(torrent_index, addr, mut window)
		return
	}

	// Send interested
	send_message(mut conn, msg_interested, []u8{}) or {
		remove_peer(torrent_index, addr, mut window)
		return
	}

	// Message loop
	mut peer_bitfield := []bool{}
	mut choked := true

	for {
		// Check if torrent is still active
		a2 := window.state[App]()
		if torrent_index >= a2.torrents.len {
			break
		}
		if a2.torrents[torrent_index].state != .downloading {
			break
		}

		msg_id, payload := read_message(mut conn) or { break }

		match msg_id {
			-1 {
				// Keep-alive
				continue
			}
			int(msg_choke) {
				choked = true
			}
			int(msg_unchoke) {
				choked = false
				// Start requesting pieces
				request_pieces(torrent_index, addr, mut conn, mut peer_bitfield, mut window)
			}
			int(msg_bitfield) {
				peer_bitfield = parse_bitfield(payload, a2.torrents[torrent_index].meta.num_pieces())
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
						// Extend bitfield
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

					handle_block(torrent_index, piece_idx, block_off, block_data, mut window)

					// Request more pieces if unchoked
					if !choked {
						request_pieces(torrent_index, addr, mut conn, mut peer_bitfield, mut
							window)
					}
				}
			}
			else {}
		}
	}

	remove_peer(torrent_index, addr, mut window)
}

fn request_pieces(torrent_index int, addr string, mut conn net.TcpConn, mut peer_bitfield []bool, mut window &gui.Window) {
	app := window.state[App]()
	if torrent_index >= app.torrents.len {
		return
	}
	torrent := app.torrents[torrent_index]

	// Count active requests for this peer
	mut active := 0
	for peer in torrent.peers {
		if peer.addr == addr {
			active = peer.active_requests
			break
		}
	}

	for active < max_pipeline {
		piece_idx := select_piece(torrent, peer_bitfield)
		if piece_idx < 0 {
			break
		}

		piece_size := torrent.meta.piece_size(piece_idx)

		// Mark piece as downloading
		window.queue_command(fn [torrent_index, piece_idx] (mut w gui.Window) {
			mut a := w.state[App]()
			if torrent_index < a.torrents.len && piece_idx < a.torrents[torrent_index].pieces.len {
				if a.torrents[torrent_index].pieces[piece_idx].state == .pending {
					a.torrents[torrent_index].pieces[piece_idx].state = .downloading
				}
			}
		})

		block_idx := torrent.pieces[piece_idx].next_missing_block()
		if block_idx < 0 {
			break
		}
		offset, length := block_params(piece_size, block_idx)

		// Send request
		send_request(mut conn, piece_idx, offset, length) or { break }

		window.queue_command(fn [torrent_index, addr] (mut w gui.Window) {
			mut a := w.state[App]()
			if torrent_index < a.torrents.len {
				for mut p in a.torrents[torrent_index].peers {
					if p.addr == addr {
						p.active_requests++
						break
					}
				}
			}
		})

		active++
	}
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
			valid := verify_piece(&torrent.meta, torrent.download_dir, piece_idx) or { false }
			if valid {
				torrent.pieces[piece_idx].state = .complete
				// Check if all pieces done
				if torrent.completed_pieces() == torrent.meta.num_pieces() {
					torrent.state = .seeding
					a.status_message = '${torrent.meta.name} - Download complete!'
				}
			} else {
				// Reset piece for re-download
				torrent.pieces[piece_idx] = new_piece_info(torrent.meta.piece_size(piece_idx))
			}
		}
	})
}

fn do_handshake(mut conn net.TcpConn, info_hash []u8, peer_id []u8) ! {
	// Send handshake: \x13BitTorrent protocol + 8 reserved + info_hash + peer_id
	mut handshake := []u8{len: 68}
	handshake[0] = 19
	pstr := 'BitTorrent protocol'.bytes()
	for i, b in pstr {
		handshake[1 + i] = b
	}
	// 8 reserved bytes are already zero
	for i in 0 .. 20 {
		handshake[28 + i] = info_hash[i]
	}
	for i in 0 .. 20 {
		handshake[48 + i] = peer_id[i]
	}

	conn.write(handshake) or { return error('failed to send handshake: ${err}') }

	// Read response handshake
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

	// Verify info_hash matches
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
	// Read 4-byte length prefix
	mut len_buf := []u8{len: 4}
	read_exact(mut conn, mut len_buf)!
	length := int(binary.big_endian_u32(len_buf[0..4]))

	if length == 0 {
		return -1, []u8{} // keep-alive
	}

	// Read message body
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
