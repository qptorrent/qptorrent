module main

import crypto.sha1

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
