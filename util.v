module main

import os

fn dbg(msg string) {
	if os.getenv('QPT_VERBOSE') == '1' {
		eprint('[qpt] ${msg}\n')
	}
}

fn hex_str(data []u8) string {
	if data.len == 0 {
		return '(empty)'
	}
	mut s := []u8{cap: data.len * 2}
	for b in data {
		s << hex_char(b >> 4)
		s << hex_char(b & 0x0f)
	}
	return s.bytestr()
}

fn format_bytes(bytes u64) string {
	if bytes < 1024 {
		return '${bytes} B'
	} else if bytes < 1024 * 1024 {
		return '${f64(bytes) / 1024.0:.1f} KB'
	} else if bytes < 1024 * 1024 * 1024 {
		return '${f64(bytes) / (1024.0 * 1024.0):.1f} MB'
	} else {
		return '${f64(bytes) / (1024.0 * 1024.0 * 1024.0):.2f} GB'
	}
}

fn format_speed(bytes_per_sec u64) string {
	if bytes_per_sec == 0 {
		return '0 B/s'
	}
	return '${format_bytes(bytes_per_sec)}/s'
}

fn format_eta(remaining_bytes u64, speed u64) string {
	if speed == 0 {
		return '∞'
	}
	secs := remaining_bytes / speed
	if secs < 60 {
		return '${secs}s'
	} else if secs < 3600 {
		return '${secs / 60}m ${secs % 60}s'
	} else if secs < 86400 {
		return '${secs / 3600}h ${(secs % 3600) / 60}m'
	} else {
		return '${secs / 86400}d ${(secs % 86400) / 3600}h'
	}
}

fn url_encode_bytes(data []u8) string {
	mut result := []u8{cap: data.len * 3}
	for b in data {
		if (b >= `A` && b <= `Z`) || (b >= `a` && b <= `z`) || (b >= `0` && b <= `9`)
			|| b == `-` || b == `_` || b == `.` || b == `~` {
			result << b
		} else {
			result << `%`
			result << hex_char(b >> 4)
			result << hex_char(b & 0x0f)
		}
	}
	return result.bytestr()
}

fn hex_char(nibble u8) u8 {
	if nibble < 10 {
		return `0` + nibble
	}
	return `A` + nibble - 10
}

fn generate_peer_id() []u8 {
	mut id := []u8{len: 20}
	prefix := '-QP0001-'.bytes()
	for i, b in prefix {
		id[i] = b
	}
	for i in prefix.len .. 20 {
		id[i] = u8(`0` + i % 10)
	}
	return id
}
