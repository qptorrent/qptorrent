module main

import crypto.sha1

// Select the next piece to download. Uses sequential order for video files,
// otherwise picks the rarest piece available from the given peer.
fn select_piece(torrent &Torrent, peer_bitfield []bool) int {
	if torrent.meta.is_video {
		return select_sequential(torrent, peer_bitfield)
	}
	return select_rarest(torrent, peer_bitfield)
}

fn select_sequential(torrent &Torrent, peer_bitfield []bool) int {
	for i, p in torrent.pieces {
		if p.state == .pending && i < peer_bitfield.len && peer_bitfield[i] {
			return i
		}
	}
	// Also check downloading pieces that need more blocks
	for i, p in torrent.pieces {
		if p.state == .downloading && i < peer_bitfield.len && peer_bitfield[i] {
			if p.next_missing_block() >= 0 {
				return i
			}
		}
	}
	return -1
}

fn select_rarest(torrent &Torrent, peer_bitfield []bool) int {
	// Count availability across all peers
	num_pieces := torrent.meta.num_pieces()
	mut availability := []int{len: num_pieces}

	for peer in torrent.peers {
		if peer.bitfield.len > 0 {
			for i in 0 .. num_pieces {
				if i < peer.bitfield.len && peer.bitfield[i] {
					availability[i]++
				}
			}
		}
	}

	mut best := -1
	mut best_avail := int(max_i32)

	for i, p in torrent.pieces {
		if p.state != .pending {
			continue
		}
		if i >= peer_bitfield.len || !peer_bitfield[i] {
			continue
		}
		if availability[i] < best_avail {
			best_avail = availability[i]
			best = i
		}
	}

	if best >= 0 {
		return best
	}

	// Fall back to downloading pieces needing blocks
	for i, p in torrent.pieces {
		if p.state == .downloading && i < peer_bitfield.len && peer_bitfield[i] {
			if p.next_missing_block() >= 0 {
				return i
			}
		}
	}
	return -1
}

fn verify_piece(meta &TorrentMetainfo, download_dir string, piece_index int) !bool {
	data := read_piece(meta, download_dir, piece_index)!
	expected := meta.piece_hash(piece_index)
	actual := sha1.sum(data)
	for i in 0 .. 20 {
		if actual[i] != expected[i] {
			return false
		}
	}
	return true
}

// Get the block offset and length for a given block index within a piece
fn block_params(piece_size int, block_index int) (int, int) {
	offset := block_index * block_size
	mut length := block_size
	if offset + length > piece_size {
		length = piece_size - offset
	}
	return offset, length
}
