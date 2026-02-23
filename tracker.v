module main

import net.http

const tracker_port = 6881

fn tracker_announce(meta &TorrentMetainfo, peer_id []u8, downloaded u64, uploaded u64, left u64) !TrackerResponse {
	// Build list of trackers to try: primary first, then announce-list
	mut trackers := []string{}
	if meta.announce.len > 0 {
		trackers << meta.announce
	}
	for t in meta.announce_list {
		if t !in trackers {
			trackers << t
		}
	}

	if trackers.len == 0 {
		return error('no announce URL')
	}

	dbg('--- Tracker announce (${trackers.len} tracker(s) to try)')

	// Try each tracker until one works
	mut last_err := ''
	for tracker_url in trackers {
		// Only support HTTP(S) trackers for now
		if !tracker_url.starts_with('http://') && !tracker_url.starts_with('https://') {
			dbg('  Skipping non-HTTP tracker: ${tracker_url}')
			continue
		}

		resp := try_tracker(tracker_url, meta.info_hash, peer_id, downloaded, uploaded,
			left) or {
			last_err = err.msg()
			dbg('  Tracker failed: ${tracker_url} -> ${err.msg()}')
			continue
		}

		dbg('  Tracker success: ${tracker_url}')
		dbg('    Peers: ${resp.peers.len}, Seeds: ${resp.seeders}, Leechers: ${resp.leechers}, Interval: ${resp.interval}s')
		if resp.peers.len > 0 {
			dbg('    First peers: ${resp.peers[..if resp.peers.len < 5 {
				resp.peers.len
			} else {
				5
			}]}')
		}
		return resp
	}

	return error('all trackers failed, last error: ${last_err}')
}

fn try_tracker(tracker_url string, info_hash []u8, peer_id []u8, downloaded u64, uploaded u64, left u64) !TrackerResponse {
	info_hash_encoded := url_encode_bytes(info_hash)
	peer_id_encoded := url_encode_bytes(peer_id)

	sep := if tracker_url.contains('?') { '&' } else { '?' }
	url := '${tracker_url}${sep}info_hash=${info_hash_encoded}&peer_id=${peer_id_encoded}&port=${tracker_port}&uploaded=${uploaded}&downloaded=${downloaded}&left=${left}&compact=1&event=started&numwant=50'

	dbg('  GET ${url[..if url.len < 200 { url.len } else { 200 }]}...')

	resp := http.get(url) or { return error('HTTP request failed: ${err}') }
	dbg('  HTTP ${resp.status_code}, body: ${resp.body.len} bytes')

	if resp.status_code != 200 {
		return error('tracker returned HTTP ${resp.status_code}')
	}

	return parse_tracker_response(resp.body.bytes())!
}

struct TrackerResponse {
	interval int
	peers    []string // "ip:port" strings
	seeders  int
	leechers int
}

fn parse_tracker_response(data []u8) !TrackerResponse {
	root := bencode_decode(data) or { return error('failed to decode tracker response: ${err}') }
	dict := bval_dict(root)

	if 'failure reason' in dict {
		reason := dict['failure reason'] or { BencodeValue([]u8{}) }
		return error('tracker error: ${bval_str(reason)}')
	}

	if 'warning message' in dict {
		warn := dict['warning message'] or { BencodeValue([]u8{}) }
		dbg('  Tracker warning: ${bval_str(warn)}')
	}

	interval_val := dict['interval'] or { BencodeValue(i64(1800)) }
	interval := if 'interval' in dict { int(bval_int(interval_val)) } else { 1800 }
	complete_val := dict['complete'] or { BencodeValue(i64(0)) }
	seeders := if 'complete' in dict { int(bval_int(complete_val)) } else { 0 }
	incomplete_val := dict['incomplete'] or { BencodeValue(i64(0)) }
	leechers := if 'incomplete' in dict { int(bval_int(incomplete_val)) } else { 0 }

	mut peers := []string{}

	if 'peers' in dict {
		peers_val := dict['peers'] or { BencodeValue([]u8{}) }
		match peers_val {
			[]u8 {
				// Compact format: 6 bytes per peer (4 IP + 2 port)
				peer_data := peers_val
				dbg('  Compact peers blob: ${peer_data.len} bytes')
				if peer_data.len % 6 == 0 {
					for i := 0; i < peer_data.len; i += 6 {
						ip := '${peer_data[i]}.${peer_data[i + 1]}.${peer_data[i + 2]}.${peer_data[
							i + 3]}'
						port := u32(peer_data[i + 4]) << 8 | u32(peer_data[i + 5])
						peers << '${ip}:${port}'
					}
				} else {
					dbg('  WARNING: peers blob not multiple of 6 (${peer_data.len} bytes)')
				}
			}
			[]BencodeValue {
				// Dictionary format
				dbg('  Dictionary peers: ${peers_val.len} entries')
				for p in peers_val {
					pd := bval_dict(p)
					ip_val := pd['ip'] or { BencodeValue([]u8{}) }
					port_val := pd['port'] or { BencodeValue(i64(0)) }
					ip := bval_str(ip_val)
					port := bval_int(port_val)
					if ip.len > 0 {
						peers << '${ip}:${port}'
					}
				}
			}
			else {
				dbg('  WARNING: peers field is neither string nor list')
			}
		}
	} else {
		dbg('  WARNING: no peers field in tracker response')
	}

	return TrackerResponse{
		interval: interval
		peers:    peers
		seeders:  seeders
		leechers: leechers
	}
}
