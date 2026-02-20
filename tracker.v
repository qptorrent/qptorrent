module main

import net.http

const tracker_port = 6881

fn tracker_announce(meta &TorrentMetainfo, peer_id []u8, downloaded u64, uploaded u64, left u64) !TrackerResponse {
	if meta.announce.len == 0 {
		return error('no announce URL')
	}

	info_hash_encoded := url_encode_bytes(meta.info_hash)
	peer_id_encoded := url_encode_bytes(peer_id)

	sep := if meta.announce.contains('?') { '&' } else { '?' }
	url := '${meta.announce}${sep}info_hash=${info_hash_encoded}&peer_id=${peer_id_encoded}&port=${tracker_port}&uploaded=${uploaded}&downloaded=${downloaded}&left=${left}&compact=1&event=started&numwant=50'

	resp := http.get(url) or { return error('tracker request failed: ${err}') }
	if resp.status_code != 200 {
		return error('tracker returned status ${resp.status_code}')
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
				if peer_data.len % 6 == 0 {
					for i := 0; i < peer_data.len; i += 6 {
						ip := '${peer_data[i]}.${peer_data[i + 1]}.${peer_data[i + 2]}.${peer_data[i + 3]}'
						port := u32(peer_data[i + 4]) << 8 | u32(peer_data[i + 5])
						peers << '${ip}:${port}'
					}
				}
			}
			[]BencodeValue {
				// Dictionary format
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
			else {}
		}
	}

	return TrackerResponse{
		interval: interval
		peers:    peers
		seeders:  seeders
		leechers: leechers
	}
}
