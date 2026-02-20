module main

import crypto.sha1
import os

const video_extensions = ['.mkv', '.mp4', '.avi', '.webm', '.mov', '.flv', '.wmv']

fn parse_torrent_file(path string) !TorrentMetainfo {
	dbg('--- Parsing torrent file: ${path}')
	data := os.read_bytes(path) or { return error('failed to read torrent file: ${err}') }
	dbg('  File size: ${data.len} bytes')
	return parse_torrent_data(data)!
}

fn parse_torrent_data(data []u8) !TorrentMetainfo {
	root := bencode_decode(data) or { return error('failed to decode torrent: ${err}') }
	root_dict := bval_dict(root)
	if root_dict.len == 0 {
		return error('torrent root is not a dictionary')
	}
	dbg('  Root dict keys: ${root_dict.keys()}')

	// Primary announce URL
	announce := if 'announce' in root_dict {
		bval_str(root_dict['announce'] or { BencodeValue([]u8{}) })
	} else {
		''
	}
	dbg('  Announce: "${announce}"')

	// Backup trackers from announce-list
	mut announce_list := []string{}
	if 'announce-list' in root_dict {
		tiers := bval_list(root_dict['announce-list'] or { BencodeValue([]BencodeValue{}) })
		for tier in tiers {
			urls := bval_list(tier)
			for u in urls {
				url_str := bval_str(u)
				if url_str.len > 0 && url_str != announce {
					announce_list << url_str
				}
			}
		}
		dbg('  Announce-list: ${announce_list.len} backup tracker(s)')
	}

	info_val := root_dict['info'] or { return error('missing info dictionary') }
	info := bval_dict(info_val)
	if info.len == 0 {
		return error('info is not a dictionary')
	}
	dbg('  Info dict keys: ${info.keys()}')

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

	dbg('  Name: "${name}"')
	dbg('  Piece length: ${piece_length}')
	dbg('  Pieces hash blob: ${pieces.len} bytes (${pieces.len / 20} pieces)')

	if piece_length == 0 || pieces.len == 0 || pieces.len % 20 != 0 {
		return error('invalid piece length (${piece_length}) or pieces data (${pieces.len} bytes, ${pieces.len % 20} remainder)')
	}

	// Parse files
	mut files := []FileInfo{}
	mut total_length := u64(0)

	if 'files' in info {
		// Multi-file torrent
		file_list := bval_list(info['files'] or { BencodeValue([]BencodeValue{}) })
		dbg('  Multi-file torrent: ${file_list.len} file(s)')
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
			dbg('    File: "${file_path}" (${format_bytes(length)})')
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
		dbg('  Single-file torrent: "${name}" (${format_bytes(length)})')
	}

	// Compute info_hash from raw info dict bytes
	raw_info := extract_raw_info(data) or { return error('failed to extract info dict: ${err}') }
	dbg('  Raw info dict: ${raw_info.len} bytes')
	info_hash := sha1.sum(raw_info)
	dbg('  Info hash: ${hex_str(info_hash)}')

	// Check if video
	is_video := check_is_video(files)
	dbg('  Is video: ${is_video}')
	dbg('  Total size: ${format_bytes(total_length)}')
	dbg('--- Parse complete')

	return TorrentMetainfo{
		announce:      announce
		announce_list: announce_list
		name:          name
		piece_length:  piece_length
		pieces:        pieces
		files:         files
		total_length:  total_length
		info_hash:     info_hash
		is_video:      is_video
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
