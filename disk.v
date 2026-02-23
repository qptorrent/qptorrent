module main

import os

fn default_download_dir() string {
	return os.join_path(os.home_dir(), 'Downloads', 'torrents')
}

fn allocate_files(meta &TorrentMetainfo, download_dir string) ! {
	for f in meta.files {
		file_path := os.join_path(download_dir, f.path)
		dir := os.dir(file_path)
		if !os.exists(dir) {
			os.mkdir_all(dir) or { return error('failed to create directory ${dir}: ${err}') }
		}
		if !os.exists(file_path) {
			// Create file with correct size
			mut fh := os.create(file_path) or {
				return error('failed to create file ${file_path}: ${err}')
			}
			if f.length > 0 {
				// Write a zero byte at the end to allocate space
				fh.seek(i64(f.length) - 1, .start) or {
					fh.close()
					return error('failed to seek in ${file_path}: ${err}')
				}
				fh.write([u8(0)]) or {
					fh.close()
					return error('failed to write to ${file_path}: ${err}')
				}
			}
			fh.close()
		}
	}
}

fn write_block(meta &TorrentMetainfo, download_dir string, piece_index int, block_offset int, data []u8) ! {
	abs_offset := u64(piece_index) * u64(meta.piece_length) + u64(block_offset)
	mut remaining := data.len
	mut data_pos := 0
	mut current_offset := abs_offset

	for f in meta.files {
		file_end := f.offset + f.length
		if current_offset >= file_end {
			continue
		}
		if current_offset < f.offset {
			break
		}

		file_offset := current_offset - f.offset
		bytes_in_file := int(if file_end - current_offset < u64(remaining) {
			file_end - current_offset
		} else {
			u64(remaining)
		})

		file_path := os.join_path(download_dir, f.path)
		mut fh := os.open_file(file_path, 'r+b') or {
			return error('failed to open ${file_path}: ${err}')
		}
		fh.seek(i64(file_offset), .start) or {
			fh.close()
			return error('failed to seek in ${file_path}: ${err}')
		}
		fh.write(data[data_pos..data_pos + bytes_in_file]) or {
			fh.close()
			return error('failed to write to ${file_path}: ${err}')
		}
		fh.close()

		data_pos += bytes_in_file
		remaining -= bytes_in_file
		current_offset += u64(bytes_in_file)

		if remaining <= 0 {
			break
		}
	}
}

fn read_piece(meta &TorrentMetainfo, download_dir string, piece_index int) ![]u8 {
	piece_size := meta.piece_size(piece_index)
	mut result := []u8{len: piece_size}
	abs_offset := u64(piece_index) * u64(meta.piece_length)
	mut remaining := piece_size
	mut result_pos := 0
	mut current_offset := abs_offset

	for f in meta.files {
		file_end := f.offset + f.length
		if current_offset >= file_end {
			continue
		}
		if current_offset < f.offset {
			break
		}

		file_offset := current_offset - f.offset
		bytes_in_file := int(if file_end - current_offset < u64(remaining) {
			file_end - current_offset
		} else {
			u64(remaining)
		})

		file_path := os.join_path(download_dir, f.path)
		mut fh := os.open(file_path) or { return error('failed to open ${file_path}: ${err}') }
		fh.seek(i64(file_offset), .start) or {
			fh.close()
			return error('failed to seek in ${file_path}: ${err}')
		}
		bytes_read := fh.read(mut result[result_pos..result_pos + bytes_in_file]) or {
			fh.close()
			return error('failed to read from ${file_path}: ${err}')
		}
		fh.close()

		result_pos += bytes_read
		remaining -= bytes_read
		current_offset += u64(bytes_read)

		if remaining <= 0 {
			break
		}
	}
	return result
}
