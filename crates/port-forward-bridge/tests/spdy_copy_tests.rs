use krust_port_forward_bridge::spdy::frame::{HeaderCompressor, HeaderDecompressor, SpdyFrame};

#[test]
fn copied_spdy_frame_supports_portforward_syn_stream_headers() {
    let frame = SpdyFrame::SynStream {
        stream_id: 1,
        headers: vec![
            ("streamType".to_string(), "data".to_string()),
            ("port".to_string(), "8080".to_string()),
            ("requestID".to_string(), "0".to_string()),
        ],
        fin: false,
    };
    let mut compressor = HeaderCompressor::new().unwrap();
    let bytes = frame.serialize_with_headers(&mut compressor).unwrap();

    let mut decompressor = HeaderDecompressor::new();
    let parsed = SpdyFrame::parse(&bytes, &mut decompressor)
        .unwrap()
        .unwrap();

    match parsed.0 {
        SpdyFrame::SynStream {
            stream_id,
            headers,
            fin,
        } => {
            assert_eq!(stream_id, 1);
            assert!(!fin);
            assert!(headers.contains(&("streamtype".to_string(), "data".to_string())));
            assert!(headers.contains(&("port".to_string(), "8080".to_string())));
            assert!(headers.contains(&("requestid".to_string(), "0".to_string())));
        }
        other => panic!("expected SYN_STREAM, got {other:?}"),
    }
}
