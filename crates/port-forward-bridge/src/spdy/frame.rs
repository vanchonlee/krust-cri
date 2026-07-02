use flate2::{Compress, Compression, Decompress, FlushCompress, FlushDecompress};

use super::dictionary::SPDY_DICT;

// ── Constants ────────────────────────────────────────────────────────────────

pub const SPDY_VERSION: u16 = 3;
pub const TYPE_SYN_STREAM: u16 = 1;
pub const TYPE_SYN_REPLY: u16 = 2;
pub const TYPE_RST_STREAM: u16 = 3;
pub const TYPE_SETTINGS: u16 = 4;
pub const TYPE_PING: u16 = 6;
pub const TYPE_GOAWAY: u16 = 7;
pub const TYPE_WINDOW_UPDATE: u16 = 9;
pub const FLAG_FIN: u8 = 0x01;

// ── Frame enum ───────────────────────────────────────────────────────────────

#[derive(Debug)]
pub enum SpdyFrame {
    SynStream {
        stream_id: u32,
        headers: Vec<(String, String)>,
        fin: bool,
    },
    SynReply {
        stream_id: u32,
        headers: Vec<(String, String)>,
        fin: bool,
    },
    RstStream {
        stream_id: u32,
        status: u32,
    },
    Settings {
        entries: Vec<(u32, u32)>,
    },
    Ping {
        id: u32,
    },
    GoAway {
        last_stream_id: u32,
        status: u32,
    },
    WindowUpdate {
        stream_id: u32,
        delta: u32,
    },
    Data {
        stream_id: u32,
        data: Vec<u8>,
        fin: bool,
    },
}

// ── Header compression ───────────────────────────────────────────────────────

pub struct HeaderCompressor {
    compress: Compress,
}

impl HeaderCompressor {
    pub fn new() -> Result<Self, String> {
        let mut compress = Compress::new(Compression::best(), true); // true = zlib format
        compress
            .set_dictionary(SPDY_DICT)
            .map_err(|e| format!("set_dictionary failed: {e}"))?;
        Ok(Self { compress })
    }

    pub fn compress_headers(&mut self, headers: &[(String, String)]) -> Result<Vec<u8>, String> {
        let nv = serialize_nv_block(headers);
        // Allocate generous output buffer (compressed may be larger than input for small inputs)
        let mut output = vec![0u8; nv.len() + 512];
        let before_out = self.compress.total_out();
        self.compress
            .compress(&nv, &mut output, FlushCompress::Sync)
            .map_err(|e| format!("zlib compress: {e}"))?;
        let written = (self.compress.total_out() - before_out) as usize;
        output.truncate(written);
        Ok(output)
    }
}

// ── Header decompression ─────────────────────────────────────────────────────

pub struct HeaderDecompressor {
    decompress: Decompress,
    dict_set: bool,
}

impl HeaderDecompressor {
    pub fn new() -> Self {
        Self {
            decompress: Decompress::new(true), // true = zlib format
            dict_set: false,
        }
    }

    pub fn decompress_headers(
        &mut self,
        compressed: &[u8],
    ) -> Result<Vec<(String, String)>, String> {
        let mut output = vec![0u8; compressed.len() * 16 + 1024]; // generous buffer

        // Track offsets relative to THIS call (total_in/total_out are cumulative)
        let in_base = self.decompress.total_in() as usize;
        let out_base = self.decompress.total_out() as usize;

        loop {
            let consumed = (self.decompress.total_in() as usize).saturating_sub(in_base);
            let produced = (self.decompress.total_out() as usize).saturating_sub(out_base);
            let remaining = &compressed[consumed..];

            if remaining.is_empty() && produced > 0 {
                output.truncate(produced);
                return parse_nv_block(&output);
            }

            let result = self.decompress.decompress(
                remaining,
                &mut output[produced..],
                FlushDecompress::Sync,
            );

            match result {
                Err(ref e) if e.needs_dictionary().is_some() => {
                    self.decompress
                        .set_dictionary(SPDY_DICT)
                        .map_err(|e| format!("set_dictionary failed: {e}"))?;
                    self.dict_set = true;
                }
                Ok(_) => {
                    let produced = (self.decompress.total_out() as usize).saturating_sub(out_base);
                    output.truncate(produced);
                    return parse_nv_block(&output);
                }
                Err(e) => return Err(format!("zlib decompress: {e}")),
            }
        }
    }
}

impl Default for HeaderDecompressor {
    fn default() -> Self {
        Self::new()
    }
}

// ── NV block helpers ─────────────────────────────────────────────────────────

fn serialize_nv_block(headers: &[(String, String)]) -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(&(headers.len() as u32).to_be_bytes());
    for (name, value) in headers {
        let name_lc = name.to_lowercase();
        buf.extend_from_slice(&(name_lc.len() as u32).to_be_bytes());
        buf.extend_from_slice(name_lc.as_bytes());
        buf.extend_from_slice(&(value.len() as u32).to_be_bytes());
        buf.extend_from_slice(value.as_bytes());
    }
    buf
}

fn parse_nv_block(data: &[u8]) -> Result<Vec<(String, String)>, String> {
    if data.len() < 4 {
        return Err(format!("NV block too short: {} bytes", data.len()));
    }
    let count = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize;
    if count > 256 {
        return Err(format!("NV block count too large: {count}"));
    }
    let mut offset = 4;
    let mut headers = Vec::with_capacity(count);

    for _ in 0..count {
        if offset + 4 > data.len() {
            return Err("NV block truncated at name length".into());
        }
        let name_len = u32::from_be_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]) as usize;
        offset += 4;

        if offset + name_len > data.len() {
            return Err("NV block truncated at name bytes".into());
        }
        let name = String::from_utf8_lossy(&data[offset..offset + name_len]).into_owned();
        offset += name_len;

        if offset + 4 > data.len() {
            return Err("NV block truncated at value length".into());
        }
        let val_len = u32::from_be_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]) as usize;
        offset += 4;

        if offset + val_len > data.len() {
            return Err("NV block truncated at value bytes".into());
        }
        let value = String::from_utf8_lossy(&data[offset..offset + val_len]).into_owned();
        offset += val_len;

        headers.push((name, value));
    }

    Ok(headers)
}

// ── Frame serialization ──────────────────────────────────────────────────────

impl SpdyFrame {
    /// Serialize frames that do NOT contain headers.
    pub fn serialize_headerless(&self) -> Vec<u8> {
        match self {
            SpdyFrame::Data {
                stream_id,
                data,
                fin,
            } => {
                let flags = if *fin { FLAG_FIN } else { 0 };
                let mut buf = Vec::with_capacity(8 + data.len());
                // stream_id with high bit = 0 (data frame marker)
                buf.extend_from_slice(&stream_id.to_be_bytes());
                buf.push(flags);
                let len = data.len() as u32;
                buf.extend_from_slice(&len.to_be_bytes()[1..4]); // 24-bit length
                buf.extend_from_slice(data);
                buf
            }
            SpdyFrame::Ping { id } => {
                let mut buf = Vec::with_capacity(12);
                buf.extend_from_slice(&(0x8000 | SPDY_VERSION).to_be_bytes());
                buf.extend_from_slice(&TYPE_PING.to_be_bytes());
                buf.push(0); // flags
                buf.extend_from_slice(&4u32.to_be_bytes()[1..4]); // length = 4
                buf.extend_from_slice(&id.to_be_bytes());
                buf
            }
            SpdyFrame::RstStream { stream_id, status } => {
                let mut buf = Vec::with_capacity(16);
                buf.extend_from_slice(&(0x8000 | SPDY_VERSION).to_be_bytes());
                buf.extend_from_slice(&TYPE_RST_STREAM.to_be_bytes());
                buf.push(0); // flags
                buf.extend_from_slice(&8u32.to_be_bytes()[1..4]); // length = 8
                buf.extend_from_slice(&stream_id.to_be_bytes());
                buf.extend_from_slice(&status.to_be_bytes());
                buf
            }
            SpdyFrame::GoAway {
                last_stream_id,
                status,
            } => {
                let mut buf = Vec::with_capacity(16);
                buf.extend_from_slice(&(0x8000 | SPDY_VERSION).to_be_bytes());
                buf.extend_from_slice(&TYPE_GOAWAY.to_be_bytes());
                buf.push(0); // flags
                buf.extend_from_slice(&8u32.to_be_bytes()[1..4]); // length = 8
                buf.extend_from_slice(&last_stream_id.to_be_bytes());
                buf.extend_from_slice(&status.to_be_bytes());
                buf
            }
            SpdyFrame::WindowUpdate { stream_id, delta } => {
                let mut buf = Vec::with_capacity(16);
                buf.extend_from_slice(&(0x8000 | SPDY_VERSION).to_be_bytes());
                buf.extend_from_slice(&TYPE_WINDOW_UPDATE.to_be_bytes());
                buf.push(0); // flags
                buf.extend_from_slice(&8u32.to_be_bytes()[1..4]); // length = 8
                buf.extend_from_slice(&stream_id.to_be_bytes());
                buf.extend_from_slice(&delta.to_be_bytes());
                buf
            }
            _ => Vec::new(), // header frames should use serialize_with_headers
        }
    }

    /// Serialize frames that contain headers (SynStream, SynReply).
    pub fn serialize_with_headers(
        &self,
        compressor: &mut HeaderCompressor,
    ) -> Result<Vec<u8>, String> {
        match self {
            SpdyFrame::SynStream {
                stream_id,
                headers,
                fin,
            } => {
                let compressed = compressor.compress_headers(headers)?;
                // payload = stream_id(4) + assoc_stream_id(4) + priority(1) + slot(1) + headers
                let payload_len = 10 + compressed.len();
                let flags = if *fin { FLAG_FIN } else { 0 };
                let mut buf = Vec::with_capacity(8 + payload_len);
                // Control header
                buf.extend_from_slice(&(0x8000 | SPDY_VERSION).to_be_bytes());
                buf.extend_from_slice(&TYPE_SYN_STREAM.to_be_bytes());
                buf.push(flags);
                buf.extend_from_slice(&(payload_len as u32).to_be_bytes()[1..4]); // 24-bit
                                                                                  // Payload
                buf.extend_from_slice(&stream_id.to_be_bytes());
                buf.extend_from_slice(&0u32.to_be_bytes()); // associated stream id
                buf.push(0); // priority << 5 (0 = highest)
                buf.push(0); // slot
                buf.extend_from_slice(&compressed);
                Ok(buf)
            }
            SpdyFrame::SynReply {
                stream_id,
                headers,
                fin,
            } => {
                let compressed = compressor.compress_headers(headers)?;
                // SPDY/3: payload = stream_id(4) + headers (no "unused" bytes)
                let payload_len = 4 + compressed.len();
                let flags = if *fin { FLAG_FIN } else { 0 };
                let mut buf = Vec::with_capacity(8 + payload_len);
                buf.extend_from_slice(&(0x8000 | SPDY_VERSION).to_be_bytes());
                buf.extend_from_slice(&TYPE_SYN_REPLY.to_be_bytes());
                buf.push(flags);
                buf.extend_from_slice(&(payload_len as u32).to_be_bytes()[1..4]);
                buf.extend_from_slice(&stream_id.to_be_bytes());
                buf.extend_from_slice(&compressed);
                Ok(buf)
            }
            // Delegate headerless frames
            other => Ok(other.serialize_headerless()),
        }
    }

    // ── Deserialization ──────────────────────────────────────────────────────

    /// Parse one frame from a byte buffer.
    /// Returns `Ok(None)` if buffer doesn't contain a complete frame.
    /// Returns `Ok(Some((frame, bytes_consumed)))` on success.
    pub fn parse(
        buf: &[u8],
        decompressor: &mut HeaderDecompressor,
    ) -> Result<Option<(Self, usize)>, String> {
        if buf.len() < 8 {
            return Ok(None);
        }

        let is_control = (buf[0] & 0x80) != 0;

        if is_control {
            let frame_type = u16::from_be_bytes([buf[2], buf[3]]);
            let flags = buf[4];
            let length = ((buf[5] as u32) << 16) | ((buf[6] as u32) << 8) | (buf[7] as u32);
            let total = 8 + length as usize;
            if buf.len() < total {
                return Ok(None);
            }

            let payload = &buf[8..total];
            let frame = match frame_type {
                TYPE_SYN_STREAM => {
                    if payload.len() < 10 {
                        return Err("SYN_STREAM payload too short".into());
                    }
                    let stream_id =
                        u32::from_be_bytes([payload[0] & 0x7f, payload[1], payload[2], payload[3]]);
                    // Skip assoc_stream_id(4) + priority(1) + slot(1) = 10 bytes before headers
                    let headers = decompressor.decompress_headers(&payload[10..])?;
                    SpdyFrame::SynStream {
                        stream_id,
                        headers,
                        fin: flags & FLAG_FIN != 0,
                    }
                }
                TYPE_SYN_REPLY => {
                    if payload.len() < 4 {
                        return Err("SYN_REPLY payload too short".into());
                    }
                    let stream_id =
                        u32::from_be_bytes([payload[0] & 0x7f, payload[1], payload[2], payload[3]]);
                    // SPDY/3: stream_id(4) then compressed headers (no "unused" bytes)
                    let headers = decompressor.decompress_headers(&payload[4..])?;
                    SpdyFrame::SynReply {
                        stream_id,
                        headers,
                        fin: flags & FLAG_FIN != 0,
                    }
                }
                TYPE_RST_STREAM => {
                    if payload.len() < 8 {
                        return Err("RST_STREAM payload too short".into());
                    }
                    let stream_id =
                        u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
                    let status =
                        u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);
                    SpdyFrame::RstStream { stream_id, status }
                }
                TYPE_PING => {
                    if payload.len() < 4 {
                        return Err("PING payload too short".into());
                    }
                    let id = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
                    SpdyFrame::Ping { id }
                }
                TYPE_GOAWAY => {
                    if payload.len() < 8 {
                        return Err("GOAWAY payload too short".into());
                    }
                    let last_id =
                        u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
                    let status =
                        u32::from_be_bytes([payload[4], payload[5], payload[6], payload[7]]);
                    SpdyFrame::GoAway {
                        last_stream_id: last_id,
                        status,
                    }
                }
                TYPE_SETTINGS => {
                    // Parse but don't use the values
                    SpdyFrame::Settings {
                        entries: Vec::new(),
                    }
                }
                TYPE_WINDOW_UPDATE => {
                    if payload.len() < 8 {
                        return Err("WINDOW_UPDATE payload too short".into());
                    }
                    let stream_id =
                        u32::from_be_bytes([payload[0] & 0x7f, payload[1], payload[2], payload[3]]);
                    let delta =
                        u32::from_be_bytes([payload[4] & 0x7f, payload[5], payload[6], payload[7]]);
                    SpdyFrame::WindowUpdate { stream_id, delta }
                }
                _ => {
                    // Unknown control frame — skip it
                    return Ok(Some((
                        SpdyFrame::Settings {
                            entries: Vec::new(),
                        },
                        total,
                    )));
                }
            };
            Ok(Some((frame, total)))
        } else {
            // Data frame — bit 31 = 0
            let stream_id = u32::from_be_bytes([buf[0] & 0x7f, buf[1], buf[2], buf[3]]);
            let flags = buf[4];
            let length = ((buf[5] as u32) << 16) | ((buf[6] as u32) << 8) | (buf[7] as u32);
            let total = 8 + length as usize;
            if buf.len() < total {
                return Ok(None);
            }
            let data = buf[8..total].to_vec();
            Ok(Some((
                SpdyFrame::Data {
                    stream_id,
                    data,
                    fin: flags & FLAG_FIN != 0,
                },
                total,
            )))
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ping_roundtrip() {
        let frame = SpdyFrame::Ping { id: 42 };
        let bytes = frame.serialize_headerless();
        assert_eq!(bytes.len(), 12);
        assert_eq!(bytes[0], 0x80); // control bit
        assert_eq!(bytes[3], TYPE_PING as u8);

        let mut decomp = HeaderDecompressor::new();
        let parsed = SpdyFrame::parse(&bytes, &mut decomp).unwrap().unwrap();
        match parsed.0 {
            SpdyFrame::Ping { id } => assert_eq!(id, 42),
            other => panic!("Expected Ping, got {:?}", other),
        }
    }

    #[test]
    fn test_data_frame_roundtrip() {
        let payload = b"hello world".to_vec();
        let frame = SpdyFrame::Data {
            stream_id: 1,
            data: payload.clone(),
            fin: false,
        };
        let bytes = frame.serialize_headerless();
        assert_eq!(bytes.len(), 8 + payload.len());

        let mut decomp = HeaderDecompressor::new();
        let parsed = SpdyFrame::parse(&bytes, &mut decomp).unwrap().unwrap();
        match parsed.0 {
            SpdyFrame::Data {
                stream_id,
                data,
                fin,
            } => {
                assert_eq!(stream_id, 1);
                assert_eq!(data, payload);
                assert!(!fin);
            }
            other => panic!("Expected Data, got {:?}", other),
        }
    }

    #[test]
    fn test_syn_stream_roundtrip() {
        let headers = vec![
            (":method".to_string(), "GET".to_string()),
            (":path".to_string(), "/".to_string()),
        ];
        let frame = SpdyFrame::SynStream {
            stream_id: 1,
            headers: headers.clone(),
            fin: false,
        };
        let mut comp = HeaderCompressor::new().expect("header compressor initializes");
        let bytes = frame
            .serialize_with_headers(&mut comp)
            .expect("SYN_STREAM serializes");

        let mut decomp = HeaderDecompressor::new();
        let parsed = SpdyFrame::parse(&bytes, &mut decomp).unwrap().unwrap();
        match parsed.0 {
            SpdyFrame::SynStream {
                stream_id,
                headers: parsed_headers,
                fin,
            } => {
                assert_eq!(stream_id, 1);
                assert!(!fin);
                assert_eq!(parsed_headers.len(), headers.len());
            }
            other => panic!("Expected SynStream, got {:?}", other),
        }
    }

    /// Regression test: SYN_REPLY has 4-byte stream_id then compressed headers.
    /// No "unused" 2-byte field (that was SPDY/2, not SPDY/3).
    #[test]
    fn test_syn_reply_roundtrip() {
        let headers = vec![
            ("streamType".to_string(), "data".to_string()),
            ("port".to_string(), "5601".to_string()),
        ];

        // Serialize a SYN_REPLY
        let mut comp = HeaderCompressor::new().expect("header compressor initializes");
        let frame = SpdyFrame::SynReply {
            stream_id: 3,
            headers: headers.clone(),
            fin: false,
        };
        let bytes = frame
            .serialize_with_headers(&mut comp)
            .expect("SYN_REPLY serializes");

        // Verify binary layout: 8-byte control header + 4-byte stream_id + compressed
        assert_eq!(bytes[0], 0x80); // control frame
        assert_eq!(bytes[1], 0x03); // version 3
        assert_eq!(u16::from_be_bytes([bytes[2], bytes[3]]), TYPE_SYN_REPLY);
        let payload_len = ((bytes[5] as u32) << 16) | ((bytes[6] as u32) << 8) | (bytes[7] as u32);
        // payload = 4 (stream_id) + compressed headers — NOT 6
        assert_eq!(payload_len as usize, 4 + (bytes.len() - 8 - 4));

        // Parse it back
        let mut decomp = HeaderDecompressor::new();
        let (parsed, consumed) = SpdyFrame::parse(&bytes, &mut decomp).unwrap().unwrap();
        assert_eq!(consumed, bytes.len());
        match parsed {
            SpdyFrame::SynReply {
                stream_id,
                headers: h,
                fin,
            } => {
                assert_eq!(stream_id, 3);
                assert!(!fin);
                assert_eq!(h.len(), 2);
                assert_eq!(h[0].0, "streamtype"); // lowercase
                assert_eq!(h[0].1, "data");
                assert_eq!(h[1].0, "port");
                assert_eq!(h[1].1, "5601");
            }
            other => panic!("Expected SynReply, got {:?}", other),
        }
    }

    /// Zlib compressor/decompressor state must carry across multiple frames.
    /// This simulates the real port-forward flow: multiple SYN_STREAMs
    /// serialized through the SAME compressor, parsed by the SAME decompressor.
    #[test]
    fn test_stateful_compression_across_frames() {
        let mut comp = HeaderCompressor::new().expect("header compressor initializes");
        let mut decomp = HeaderDecompressor::new();

        // Frame 1: error stream
        let f1 = SpdyFrame::SynStream {
            stream_id: 1,
            headers: vec![
                ("streamType".to_string(), "error".to_string()),
                ("port".to_string(), "8080".to_string()),
                ("requestID".to_string(), "0".to_string()),
            ],
            fin: false,
        };
        let b1 = f1
            .serialize_with_headers(&mut comp)
            .expect("first SYN_STREAM serializes");

        // Frame 2: data stream (same port, same requestID — different streamType)
        let f2 = SpdyFrame::SynStream {
            stream_id: 3,
            headers: vec![
                ("streamType".to_string(), "data".to_string()),
                ("port".to_string(), "8080".to_string()),
                ("requestID".to_string(), "0".to_string()),
            ],
            fin: false,
        };
        let b2 = f2
            .serialize_with_headers(&mut comp)
            .expect("second SYN_STREAM serializes");

        // Frame 3: second connection's error stream
        let f3 = SpdyFrame::SynStream {
            stream_id: 5,
            headers: vec![
                ("streamType".to_string(), "error".to_string()),
                ("port".to_string(), "8080".to_string()),
                ("requestID".to_string(), "1".to_string()),
            ],
            fin: false,
        };
        let b3 = f3
            .serialize_with_headers(&mut comp)
            .expect("third SYN_STREAM serializes");

        // Parse all three with the SAME decompressor (stateful zlib)
        let (p1, c1) = SpdyFrame::parse(&b1, &mut decomp).unwrap().unwrap();
        assert_eq!(c1, b1.len());
        match p1 {
            SpdyFrame::SynStream {
                stream_id, headers, ..
            } => {
                assert_eq!(stream_id, 1);
                assert_eq!(headers.len(), 3);
                assert_eq!(headers[0].1, "error");
            }
            other => panic!("Frame 1: expected SynStream, got {:?}", other),
        }

        let (p2, c2) = SpdyFrame::parse(&b2, &mut decomp).unwrap().unwrap();
        assert_eq!(c2, b2.len());
        match p2 {
            SpdyFrame::SynStream {
                stream_id, headers, ..
            } => {
                assert_eq!(stream_id, 3);
                assert_eq!(headers.len(), 3);
                assert_eq!(headers[0].1, "data");
            }
            other => panic!("Frame 2: expected SynStream, got {:?}", other),
        }

        let (p3, c3) = SpdyFrame::parse(&b3, &mut decomp).unwrap().unwrap();
        assert_eq!(c3, b3.len());
        match p3 {
            SpdyFrame::SynStream {
                stream_id, headers, ..
            } => {
                assert_eq!(stream_id, 5);
                assert_eq!(headers.len(), 3);
                assert_eq!(headers[2].1, "1"); // requestID = "1"
            }
            other => panic!("Frame 3: expected SynStream, got {:?}", other),
        }

        // Verify compression actually leverages state (frame 2 & 3 should be smaller than frame 1
        // due to zlib learning the patterns)
        assert!(
            b2.len() <= b1.len(),
            "frame 2 ({}) should be <= frame 1 ({})",
            b2.len(),
            b1.len()
        );
    }

    /// Parser must return None for incomplete frames and succeed once all bytes arrive.
    /// Simulates the direct SPDY transport where TCP reads deliver arbitrary chunks.
    #[test]
    fn test_partial_frame_parsing() {
        let mut comp = HeaderCompressor::new().expect("header compressor initializes");
        let frame = SpdyFrame::SynStream {
            stream_id: 1,
            headers: vec![
                ("streamType".to_string(), "data".to_string()),
                ("port".to_string(), "5601".to_string()),
                ("requestID".to_string(), "0".to_string()),
            ],
            fin: false,
        };
        let full_bytes = frame
            .serialize_with_headers(&mut comp)
            .expect("SYN_STREAM serializes");
        assert!(full_bytes.len() > 20, "frame should be non-trivial size");

        let mut decomp = HeaderDecompressor::new();

        // Feed just 4 bytes — not enough for frame header (needs 8)
        assert!(SpdyFrame::parse(&full_bytes[..4], &mut decomp)
            .unwrap()
            .is_none());

        // Feed 8 bytes — header complete but payload missing
        assert!(SpdyFrame::parse(&full_bytes[..8], &mut decomp)
            .unwrap()
            .is_none());

        // Feed half the frame
        let half = full_bytes.len() / 2;
        assert!(SpdyFrame::parse(&full_bytes[..half], &mut decomp)
            .unwrap()
            .is_none());

        // Feed complete frame — should parse successfully
        let (parsed, consumed) = SpdyFrame::parse(&full_bytes, &mut decomp).unwrap().unwrap();
        assert_eq!(consumed, full_bytes.len());
        match parsed {
            SpdyFrame::SynStream {
                stream_id, headers, ..
            } => {
                assert_eq!(stream_id, 1);
                assert_eq!(headers.len(), 3);
            }
            other => panic!("Expected SynStream, got {:?}", other),
        }

        // Feed two frames concatenated — should parse first, leave second in buffer
        let mut decomp2 = HeaderDecompressor::new();
        let f_a = SpdyFrame::Ping { id: 7 };
        let f_b = SpdyFrame::Data {
            stream_id: 1,
            data: b"test".to_vec(),
            fin: true,
        };
        let mut concat = f_a.serialize_headerless();
        concat.extend_from_slice(&f_b.serialize_headerless());

        // First parse: gets PING
        let (pa, ca) = SpdyFrame::parse(&concat, &mut decomp2).unwrap().unwrap();
        assert_eq!(ca, 12); // PING is 12 bytes
        match pa {
            SpdyFrame::Ping { id } => assert_eq!(id, 7),
            other => panic!("Expected Ping, got {:?}", other),
        }

        // Second parse: gets DATA from remaining bytes
        let (pb, cb) = SpdyFrame::parse(&concat[ca..], &mut decomp2)
            .unwrap()
            .unwrap();
        assert_eq!(cb, concat.len() - ca);
        match pb {
            SpdyFrame::Data {
                stream_id,
                data,
                fin,
            } => {
                assert_eq!(stream_id, 1);
                assert_eq!(data, b"test");
                assert!(fin);
            }
            other => panic!("Expected Data, got {:?}", other),
        }
    }
}
