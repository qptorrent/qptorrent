module main

type BencodeValue = []BencodeValue | []u8 | i64 | map[string]BencodeValue

struct BencodeDecoder {
	data []u8
mut:
	pos int
}

struct BencodeError {
	Error
	msg string
	pos int
}

fn (e BencodeError) msg() string {
	return 'bencode error at position ${e.pos}: ${e.msg}'
}

fn bencode_decode(data []u8) !BencodeValue {
	mut d := BencodeDecoder{
		data: data
	}
	return d.decode_value()!
}

fn (mut d BencodeDecoder) decode_value() !BencodeValue {
	if d.pos >= d.data.len {
		return BencodeError{
			msg: 'unexpected end of data'
			pos: d.pos
		}
	}
	ch := d.data[d.pos]
	if ch == `i` {
		return d.decode_int()!
	} else if ch >= `0` && ch <= `9` {
		return d.decode_string()!
	} else if ch == `l` {
		return d.decode_list()!
	} else if ch == `d` {
		return d.decode_dict()!
	}
	return BencodeError{
		msg: "unexpected character '${[ch].bytestr()}'"
		pos: d.pos
	}
}

fn (mut d BencodeDecoder) decode_int() !i64 {
	d.pos++ // skip 'i'
	start := d.pos
	for d.pos < d.data.len && d.data[d.pos] != `e` {
		d.pos++
	}
	if d.pos >= d.data.len {
		return BencodeError{
			msg: 'unterminated integer'
			pos: start
		}
	}
	num_str := d.data[start..d.pos].bytestr()
	d.pos++ // skip 'e'
	return num_str.i64()
}

fn (mut d BencodeDecoder) decode_string() ![]u8 {
	start := d.pos
	for d.pos < d.data.len && d.data[d.pos] != `:` {
		d.pos++
	}
	if d.pos >= d.data.len {
		return BencodeError{
			msg: 'unterminated string length'
			pos: start
		}
	}
	length := d.data[start..d.pos].bytestr().int()
	d.pos++ // skip ':'
	if d.pos + length > d.data.len {
		return BencodeError{
			msg: 'string length exceeds data'
			pos: start
		}
	}
	result := d.data[d.pos..d.pos + length].clone()
	d.pos += length
	return result
}

fn (mut d BencodeDecoder) decode_list() ![]BencodeValue {
	d.pos++ // skip 'l'
	mut list := []BencodeValue{}
	for d.pos < d.data.len && d.data[d.pos] != `e` {
		list << d.decode_value()!
	}
	if d.pos >= d.data.len {
		return BencodeError{
			msg: 'unterminated list'
			pos: d.pos
		}
	}
	d.pos++ // skip 'e'
	return list
}

fn (mut d BencodeDecoder) decode_dict() !map[string]BencodeValue {
	d.pos++ // skip 'd'
	mut dict := map[string]BencodeValue{}
	for d.pos < d.data.len && d.data[d.pos] != `e` {
		key := d.decode_string()!
		value := d.decode_value()!
		dict[key.bytestr()] = value
	}
	if d.pos >= d.data.len {
		return BencodeError{
			msg: 'unterminated dict'
			pos: d.pos
		}
	}
	d.pos++ // skip 'e'
	return dict
}

// Extract raw bytes of the info dictionary for SHA1 hashing
fn extract_raw_info(data []u8) ![]u8 {
	// Find "4:info" followed by a dict 'd'
	for i := 0; i < data.len - 6; i++ {
		if data[i] == `4` && data[i + 1] == `:` && data[i + 2] == `i` && data[i + 3] == `n`
			&& data[i + 4] == `f` && data[i + 5] == `o` {
			start := i + 6
			if start >= data.len || data[start] != `d` {
				continue
			}
			// Parse through the dict to find its end
			end := find_bencode_end(data, start)!
			return data[start..end]
		}
	}
	return BencodeError{
		msg: 'info dictionary not found'
		pos: 0
	}
}

fn find_bencode_end(data []u8, start int) !int {
	mut pos := start
	if pos >= data.len {
		return BencodeError{
			msg: 'unexpected end'
			pos: pos
		}
	}
	ch := data[pos]
	if ch == `i` {
		pos++ // skip 'i'
		for pos < data.len && data[pos] != `e` {
			pos++
		}
		return pos + 1
	} else if ch >= `0` && ch <= `9` {
		len_start := pos
		for pos < data.len && data[pos] != `:` {
			pos++
		}
		length := data[len_start..pos].bytestr().int()
		return pos + 1 + length
	} else if ch == `l` {
		pos++ // skip 'l'
		for pos < data.len && data[pos] != `e` {
			pos = find_bencode_end(data, pos)!
		}
		return pos + 1
	} else if ch == `d` {
		pos++ // skip 'd'
		for pos < data.len && data[pos] != `e` {
			// key (string)
			pos = find_bencode_end(data, pos)!
			// value
			pos = find_bencode_end(data, pos)!
		}
		return pos + 1
	}
	return BencodeError{
		msg: 'invalid bencode'
		pos: pos
	}
}

// Encode a BencodeValue back to bytes
fn bencode_encode(val BencodeValue) []u8 {
	mut result := []u8{}
	match val {
		i64 {
			result << `i`
			result << val.str().bytes()
			result << `e`
		}
		[]u8 {
			result << val.len.str().bytes()
			result << `:`
			result << val
		}
		[]BencodeValue {
			result << `l`
			for item in val {
				result << bencode_encode(item)
			}
			result << `e`
		}
		map[string]BencodeValue {
			result << `d`
			// Sort keys for canonical encoding
			mut keys := val.keys()
			keys.sort()
			for key in keys {
				result << key.len.str().bytes()
				result << `:`
				result << key.bytes()
				result << bencode_encode(val[key] or { BencodeValue(i64(0)) })
			}
			result << `e`
		}
	}
	return result
}

// Helper to get a string from a BencodeValue
fn bval_str(val BencodeValue) string {
	if val is []u8 {
		return val.bytestr()
	}
	return ''
}

// Helper to get bytes from a BencodeValue
fn bval_bytes(val BencodeValue) []u8 {
	if val is []u8 {
		return val
	}
	return []u8{}
}

// Helper to get int from a BencodeValue
fn bval_int(val BencodeValue) i64 {
	if val is i64 {
		return val
	}
	return 0
}

// Helper to get dict from a BencodeValue
fn bval_dict(val BencodeValue) map[string]BencodeValue {
	if val is map[string]BencodeValue {
		return val
	}
	return map[string]BencodeValue{}
}

// Helper to get list from a BencodeValue
fn bval_list(val BencodeValue) []BencodeValue {
	if val is []BencodeValue {
		return val
	}
	return []BencodeValue{}
}
