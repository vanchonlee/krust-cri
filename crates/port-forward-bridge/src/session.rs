use std::collections::HashMap;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;

use crate::bridge::BridgeRequest;
use crate::spdy::frame::{HeaderCompressor, HeaderDecompressor, SpdyFrame};

type StreamKey = (String, u16);

#[derive(Debug)]
enum WriterMessage {
    Frame(SpdyFrame),
    Close,
}

#[derive(Debug)]
struct DataStream {
    tcp_tx: mpsc::Sender<Vec<u8>>,
    key: StreamKey,
}

pub async fn run_spdy_port_forward_session<S>(io: S, request: BridgeRequest) -> Result<(), String>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut reader, writer) = tokio::io::split(io);
    let (writer_tx, writer_rx) = mpsc::channel::<WriterMessage>(256);
    let writer_task = tokio::spawn(write_spdy_frames(writer, writer_rx));

    let mut decompressor = HeaderDecompressor::new();
    let mut read_buf = Vec::new();
    let mut data_streams: HashMap<u32, DataStream> = HashMap::new();
    let mut error_streams: HashMap<StreamKey, u32> = HashMap::new();
    let mut buf = vec![0u8; 64 * 1024];

    loop {
        let n = reader.read(&mut buf).await.map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        read_buf.extend_from_slice(&buf[..n]);
        while let Some((frame, consumed)) = SpdyFrame::parse(&read_buf, &mut decompressor)? {
            read_buf.drain(..consumed);
            handle_frame(
                frame,
                &request,
                &writer_tx,
                &mut data_streams,
                &mut error_streams,
            )
            .await?;
        }
    }

    let _ = writer_tx.send(WriterMessage::Close).await;
    writer_task.await.map_err(|e| e.to_string())??;
    Ok(())
}

async fn handle_frame(
    frame: SpdyFrame,
    request: &BridgeRequest,
    writer_tx: &mpsc::Sender<WriterMessage>,
    data_streams: &mut HashMap<u32, DataStream>,
    error_streams: &mut HashMap<StreamKey, u32>,
) -> Result<(), String> {
    match frame {
        SpdyFrame::SynStream {
            stream_id,
            headers,
            fin: _,
        } => {
            let stream_type = header_value(&headers, "streamtype")
                .ok_or_else(|| "missing streamType header".to_string())?;
            let request_id = header_value(&headers, "requestid")
                .ok_or_else(|| "missing requestID header".to_string())?;
            let port = header_value(&headers, "port")
                .ok_or_else(|| "missing port header".to_string())?
                .parse::<u16>()
                .map_err(|_| "invalid port header".to_string())?;
            if !request.ports.contains(&port) {
                return Err(format!("port {port} was not authorized by CRI"));
            }

            send_syn_reply(writer_tx, stream_id).await?;
            let key = (request_id.to_string(), port);

            match stream_type {
                "error" => {
                    error_streams.insert(key, stream_id);
                }
                "data" => {
                    match tokio::time::timeout(
                        std::time::Duration::from_secs(2),
                        TcpStream::connect((request.target.as_str(), port)),
                    )
                    .await
                    .map_err(|_| "target TCP dial timed out".to_string())
                    .and_then(|result| result.map_err(|e| e.to_string()))
                    {
                        Ok(tcp) => {
                            let (tcp_reader, tcp_writer) = tcp.into_split();
                            let (tcp_tx, tcp_rx) = mpsc::channel::<Vec<u8>>(256);
                            data_streams.insert(
                                stream_id,
                                DataStream {
                                    tcp_tx,
                                    key: key.clone(),
                                },
                            );
                            tokio::spawn(copy_tcp_to_spdy(
                                stream_id,
                                tcp_reader,
                                writer_tx.clone(),
                            ));
                            tokio::spawn(copy_spdy_to_tcp(tcp_writer, tcp_rx));
                        }
                        Err(e) => {
                            send_error(writer_tx, error_streams.get(&key).copied(), e.to_string())
                                .await?;
                        }
                    }
                }
                other => return Err(format!("unsupported streamType {other}")),
            }
        }
        SpdyFrame::Data {
            stream_id,
            data,
            fin,
        } => {
            if let Some(stream) = data_streams.get(&stream_id) {
                if !data.is_empty() {
                    let _ = stream.tcp_tx.send(data).await;
                }
                if fin {
                    let key = stream.key.clone();
                    data_streams.remove(&stream_id);
                    close_error_stream(writer_tx, error_streams.remove(&key)).await?;
                }
            }
        }
        SpdyFrame::Ping { id } => {
            writer_tx
                .send(WriterMessage::Frame(SpdyFrame::Ping { id }))
                .await
                .map_err(|_| "SPDY writer closed".to_string())?;
        }
        SpdyFrame::RstStream { stream_id, .. } => {
            data_streams.remove(&stream_id);
        }
        SpdyFrame::GoAway { .. } => return Err("SPDY GOAWAY received".to_string()),
        _ => {}
    }

    Ok(())
}

async fn write_spdy_frames<W>(
    mut writer: tokio::io::WriteHalf<W>,
    mut rx: mpsc::Receiver<WriterMessage>,
) -> Result<(), String>
where
    W: AsyncWrite + Unpin,
{
    let mut compressor = HeaderCompressor::new()?;
    while let Some(message) = rx.recv().await {
        match message {
            WriterMessage::Frame(frame) => {
                let bytes = match frame {
                    SpdyFrame::SynReply { .. } | SpdyFrame::SynStream { .. } => {
                        frame.serialize_with_headers(&mut compressor)?
                    }
                    _ => frame.serialize_headerless(),
                };
                writer.write_all(&bytes).await.map_err(|e| e.to_string())?;
            }
            WriterMessage::Close => break,
        }
    }
    writer.shutdown().await.map_err(|e| e.to_string())
}

async fn send_syn_reply(
    writer_tx: &mpsc::Sender<WriterMessage>,
    stream_id: u32,
) -> Result<(), String> {
    writer_tx
        .send(WriterMessage::Frame(SpdyFrame::SynReply {
            stream_id,
            headers: vec![
                ("status".to_string(), "200 OK".to_string()),
                ("version".to_string(), "HTTP/1.1".to_string()),
            ],
            fin: false,
        }))
        .await
        .map_err(|_| "SPDY writer closed".to_string())
}

async fn send_error(
    writer_tx: &mpsc::Sender<WriterMessage>,
    error_stream_id: Option<u32>,
    message: String,
) -> Result<(), String> {
    if let Some(stream_id) = error_stream_id {
        writer_tx
            .send(WriterMessage::Frame(SpdyFrame::Data {
                stream_id,
                data: message.into_bytes(),
                fin: true,
            }))
            .await
            .map_err(|_| "SPDY writer closed".to_string())?;
    }
    Ok(())
}

async fn close_error_stream(
    writer_tx: &mpsc::Sender<WriterMessage>,
    error_stream_id: Option<u32>,
) -> Result<(), String> {
    if let Some(stream_id) = error_stream_id {
        writer_tx
            .send(WriterMessage::Frame(SpdyFrame::Data {
                stream_id,
                data: Vec::new(),
                fin: true,
            }))
            .await
            .map_err(|_| "SPDY writer closed".to_string())?;
    }
    Ok(())
}

async fn copy_tcp_to_spdy(
    stream_id: u32,
    mut tcp_reader: tokio::net::tcp::OwnedReadHalf,
    writer_tx: mpsc::Sender<WriterMessage>,
) {
    let mut buf = vec![0u8; 32 * 1024];
    loop {
        match tcp_reader.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => {
                if writer_tx
                    .send(WriterMessage::Frame(SpdyFrame::Data {
                        stream_id,
                        data: buf[..n].to_vec(),
                        fin: false,
                    }))
                    .await
                    .is_err()
                {
                    return;
                }
            }
            Err(_) => break,
        }
    }
    let _ = writer_tx
        .send(WriterMessage::Frame(SpdyFrame::Data {
            stream_id,
            data: Vec::new(),
            fin: true,
        }))
        .await;
}

async fn copy_spdy_to_tcp(
    mut tcp_writer: tokio::net::tcp::OwnedWriteHalf,
    mut rx: mpsc::Receiver<Vec<u8>>,
) {
    while let Some(data) = rx.recv().await {
        if tcp_writer.write_all(&data).await.is_err() {
            break;
        }
    }
    let _ = tcp_writer.shutdown().await;
}

fn header_value<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

#[cfg(test)]
mod tests {
    use tokio::net::TcpListener;

    use super::*;
    use crate::spdy::frame::{HeaderCompressor, HeaderDecompressor};

    #[tokio::test]
    async fn relays_spdy_data_stream_to_tcp_target() {
        let echo = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = echo.local_addr().unwrap().port();
        tokio::spawn(async move {
            let (mut socket, _) = echo.accept().await.unwrap();
            let mut buf = [0u8; 1024];
            let n = socket.read(&mut buf).await.unwrap();
            socket.write_all(&buf[..n]).await.unwrap();
        });

        let (mut client, server) = tokio::io::duplex(64 * 1024);
        let request = BridgeRequest {
            sandbox_id: "pod-test".to_string(),
            target: "127.0.0.1".to_string(),
            ports: vec![port],
        };
        tokio::spawn(run_spdy_port_forward_session(server, request));

        let mut compressor = HeaderCompressor::new().unwrap();
        write_frame(
            &mut client,
            SpdyFrame::SynStream {
                stream_id: 1,
                headers: vec![
                    ("streamType".to_string(), "error".to_string()),
                    ("port".to_string(), port.to_string()),
                    ("requestID".to_string(), "0".to_string()),
                ],
                fin: false,
            },
            &mut compressor,
        )
        .await;
        write_frame(
            &mut client,
            SpdyFrame::SynStream {
                stream_id: 3,
                headers: vec![
                    ("streamType".to_string(), "data".to_string()),
                    ("port".to_string(), port.to_string()),
                    ("requestID".to_string(), "0".to_string()),
                ],
                fin: false,
            },
            &mut compressor,
        )
        .await;
        write_frame(
            &mut client,
            SpdyFrame::Data {
                stream_id: 3,
                data: b"hello".to_vec(),
                fin: false,
            },
            &mut compressor,
        )
        .await;

        let frames = read_frames_until_data(&mut client, 3).await;
        assert!(frames
            .iter()
            .any(|frame| matches!(frame, SpdyFrame::SynReply { stream_id: 1, .. })));
        assert!(frames
            .iter()
            .any(|frame| matches!(frame, SpdyFrame::SynReply { stream_id: 3, .. })));
        assert!(frames.iter().any(|frame| {
            matches!(
                frame,
                SpdyFrame::Data {
                    stream_id: 3,
                    data,
                    fin: false
                } if data == b"hello"
            )
        }));
    }

    async fn write_frame<W>(writer: &mut W, frame: SpdyFrame, compressor: &mut HeaderCompressor)
    where
        W: AsyncWrite + Unpin,
    {
        let bytes = match frame {
            SpdyFrame::SynStream { .. } | SpdyFrame::SynReply { .. } => {
                frame.serialize_with_headers(compressor).unwrap()
            }
            _ => frame.serialize_headerless(),
        };
        writer.write_all(&bytes).await.unwrap();
    }

    async fn read_frames_until_data<R>(reader: &mut R, data_stream_id: u32) -> Vec<SpdyFrame>
    where
        R: AsyncRead + Unpin,
    {
        let mut frames = Vec::new();
        let mut decompressor = HeaderDecompressor::new();
        let mut read_buf = Vec::new();
        let mut buf = [0u8; 8192];
        loop {
            let n = reader.read(&mut buf).await.unwrap();
            assert_ne!(n, 0);
            read_buf.extend_from_slice(&buf[..n]);
            while let Some((frame, consumed)) =
                SpdyFrame::parse(&read_buf, &mut decompressor).unwrap()
            {
                read_buf.drain(..consumed);
                let done = matches!(
                    &frame,
                    SpdyFrame::Data {
                        stream_id,
                        data,
                        fin: false
                    } if *stream_id == data_stream_id && data == b"hello"
                );
                frames.push(frame);
                if done {
                    return frames;
                }
            }
        }
    }
}
