module main

import crypto.sha1
import os

const video_extensions = ['.mkv', '.mp4', '.avi', '.webm', '.mov', '.flv', '.wmv']

fn parse_torrent_file(path string) !TorrentMetainfo {
	data := os.read_bytes(path) or { return error('failed to read torrent file: ${err}') }
	return parse_torrent_data(data)!
}

fn parse_torrent_data(data []u8) !TorrentMetainfo {
	root := bencode_decode(data) or { return error('failed to decode torrent: ${err}') }
	root_dict := bval_dict(root)
	if root_dict.len == 0 {
		return error('torrent root is not a dictionary')
	}

	announce := if 'announce' in root_dict {
		bval_str(root_dict['announce'] or { BencodeValue([]u8{}) })
	} else {
		''
	}

	info_val := root_dict['info'] or { return error('missing info dictionary') }
	info := bval_dict(info_val)
	if info.len == 0 {
		return error('info is not a dictionary')
	}

	name := if 'name' in info { bval_str(info['name'] or { BencodeValue([]u8{}) }) } else { 'unknown' }
	piece_length := if 'piece length' in info {
		int(bval_int(info['piece length'] or { BencodeValue(i64(0)) }))
	} else {
		0
	}
	pieces := if 'pieces' in info {
		bval_bytes(info['pieces'] or { BencodeValue([]u8{}) })
	} else {
		[]u8{}
	}

	if piece_length == 0 || pieces.len == 0 || pieces.len % 20 != 0 {
		return error('invalid piece length or pieces data')
	}

	// Parse files
	mut files := []FileInfo{}
	mut total_length := u64(0)

	if 'files' in info {
		// Multi-file torrent
		file_list := bval_list(info['files'] or { BencodeValue([]BencodeValue{}) })
		for f in file_list {
			fd := bval_dict(f)
			length := u64(bval_int(fd['length'] or { BencodeValue(i64(0)) }))
			path_list := bval_list(fd['path'] or { BencodeValue([]BencodeValue{}) })
			mut path_parts := []string{}
			for p in path_list {
				path_parts << bval_str(p)
			}
			file_path := os.join_path(name, ...path_parts)
			files << FileInfo{
				path:   file_path
				length: length
				offset: total_length
			}
			total_length += length
		}
	} else {
		// Single-file torrent
		length := u64(bval_int(info['length'] or { BencodeValue(i64(0)) }))
		files << FileInfo{
			path:   name
			length: length
			offset: 0
		}
		total_length = length
	}

	// Compute info_hash
	raw_info := extract_raw_info(data) or { return error('failed to extract info dict: ${err}') }
	info_hash := sha1.sum(raw_info)

	// Check if video
	is_video := check_is_video(files)

	return TorrentMetainfo{
		announce:     announce
		name:         name
		piece_length: piece_length
		pieces:       pieces
		files:        files
		total_length: total_length
		info_hash:    info_hash
		is_video:     is_video
	}
}

fn check_is_video(files []FileInfo) bool {
	// Find largest file and check extension
	mut largest_size := u64(0)
	mut largest_path := ''
	for f in files {
		if f.length > largest_size {
			largest_size = f.length
			largest_path = f.path
		}
	}
	ext := os.file_ext(largest_path).to_lower()
	return ext in video_extensions
}
