module main

import gui
import time

const block_size = 16384 // 16 KB
const max_peers = 15
const max_pipeline = 5

enum TorrentState {
	queued
	checking
	downloading
	paused
	seeding
	error
}

fn (s TorrentState) str() string {
	return match s {
		.queued { 'Queued' }
		.checking { 'Checking' }
		.downloading { 'Downloading' }
		.paused { 'Paused' }
		.seeding { 'Seeding' }
		.error { 'Error' }
	}
}

enum PieceState {
	pending
	downloading
	complete
}

struct FileInfo {
	path   string
	length u64
	offset u64 // absolute offset within the torrent
}

struct TorrentMetainfo {
	announce      string
	announce_list []string // backup trackers from announce-list
	name          string
	piece_length  int
	pieces        []u8 // concatenated 20-byte SHA1 hashes
	files         []FileInfo
	total_length  u64
	info_hash     []u8 // 20 bytes
	is_video      bool
}

fn (m &TorrentMetainfo) num_pieces() int {
	return m.pieces.len / 20
}

fn (m &TorrentMetainfo) piece_hash(index int) []u8 {
	start := index * 20
	return m.pieces[start..start + 20]
}

fn (m &TorrentMetainfo) piece_size(index int) int {
	if index == m.num_pieces() - 1 {
		remainder := int(m.total_length % u64(m.piece_length))
		if remainder != 0 {
			return remainder
		}
	}
	return m.piece_length
}

struct PieceInfo {
mut:
	state      PieceState
	blocks     []bool // true if block received
	num_blocks int
	downloaded int // bytes downloaded so far
	size       int
}

fn new_piece_info(size int) PieceInfo {
	num_blocks := (size + block_size - 1) / block_size
	return PieceInfo{
		state:      .pending
		blocks:     []bool{len: num_blocks, init: false}
		num_blocks: num_blocks
		downloaded: 0
		size:       size
	}
}

fn (p &PieceInfo) is_complete() bool {
	for b in p.blocks {
		if !b {
			return false
		}
	}
	return true
}

fn (p &PieceInfo) next_missing_block() int {
	for i, b in p.blocks {
		if !b {
			return i
		}
	}
	return -1
}

struct PeerInfo {
mut:
	addr            string
	connected       bool
	choked          bool = true
	interested      bool
	bitfield        []bool
	download_speed  u64
	bytes_this_tick u64
	active_requests int
}

@[heap]
struct Torrent {
mut:
	meta            TorrentMetainfo
	pieces          []PieceInfo
	peers           []PeerInfo
	state           TorrentState = .queued
	downloaded      u64
	uploaded        u64
	download_speed  u64
	upload_speed    u64
	prev_downloaded u64
	seeds           int
	leeches         int
	error_message   string
	download_dir    string
}

fn (t &Torrent) progress() f64 {
	if t.meta.total_length == 0 {
		return 0.0
	}
	return f64(t.downloaded) / f64(t.meta.total_length)
}

fn (t &Torrent) remaining() u64 {
	if t.meta.total_length <= t.downloaded {
		return 0
	}
	return t.meta.total_length - t.downloaded
}

fn (t &Torrent) completed_pieces() int {
	mut count := 0
	for p in t.pieces {
		if p.state == .complete {
			count++
		}
	}
	return count
}

@[heap]
struct App {
mut:
	torrents       []&Torrent
	selected       map[int]bool
	download_dir   string
	status_message string
	total_down     u64
	total_up       u64
	peer_id        []u8
	window         &gui.Window = unsafe { nil }
	last_tick          time.Time   = time.now()
	pending_paths      []string // torrent files to load on init (from CLI args)
	last_click_row     int = -1
	last_click_frame   u64
}

fn new_app() &App {
	return &App{
		download_dir:   default_download_dir()
		status_message: 'Ready'
		peer_id:        generate_peer_id()
	}
}
