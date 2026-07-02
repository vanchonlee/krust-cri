use std::collections::HashMap;
use std::net::IpAddr;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::session::run_spdy_port_forward_session;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeRequest {
    pub sandbox_id: String,
    pub target: String,
    pub ports: Vec<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpUpgradeRequest {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>,
}

pub fn parse_http_upgrade_request(raw: &str) -> Result<HttpUpgradeRequest, String> {
    let mut lines = raw.split("\r\n");
    let request_line = lines
        .next()
        .ok_or_else(|| "missing request line".to_string())?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts
        .next()
        .ok_or_else(|| "missing method".to_string())?
        .to_string();
    let path = request_parts
        .next()
        .ok_or_else(|| "missing path".to_string())?
        .to_string();
    let version = request_parts
        .next()
        .ok_or_else(|| "missing HTTP version".to_string())?;
    if version != "HTTP/1.1" {
        return Err("unsupported HTTP version".to_string());
    }

    let mut headers = HashMap::new();
    for line in lines {
        if line.is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else {
            return Err("malformed header".to_string());
        };
        headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
    }

    Ok(HttpUpgradeRequest {
        method,
        path,
        headers,
    })
}

pub fn parse_bridge_request(path: &str) -> Result<BridgeRequest, String> {
    let (route, params) = parse_query(path);
    let sandbox_id = route
        .strip_prefix("/portforward/")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "path must start with /portforward/<sandbox>".to_string())?;
    let target = params
        .get("target")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "missing target".to_string())?;
    if !valid_target(target) {
        return Err("target must be an IP address".to_string());
    }
    let ports = params
        .get("ports")
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "missing ports".to_string())?;
    let mut ports = ports
        .split(',')
        .map(|raw| {
            raw.parse::<u16>()
                .map_err(|_| format!("invalid port: {raw}"))
                .and_then(|port| {
                    if port == 0 {
                        Err("port must be greater than zero".to_string())
                    } else {
                        Ok(port)
                    }
                })
        })
        .collect::<Result<Vec<_>, _>>()?;
    ports.sort_unstable();
    ports.dedup();

    Ok(BridgeRequest {
        sandbox_id: sandbox_id.to_string(),
        target: target.to_string(),
        ports,
    })
}

pub fn is_spdy_upgrade(request: &HttpUpgradeRequest) -> bool {
    let connection = request
        .headers
        .get("connection")
        .map(|value| value.to_ascii_lowercase())
        .unwrap_or_default();
    let upgrade = request
        .headers
        .get("upgrade")
        .map(|value| value.to_ascii_lowercase())
        .unwrap_or_default();

    request.method.eq_ignore_ascii_case("POST")
        && connection.split(',').any(|part| part.trim() == "upgrade")
        && upgrade == "spdy/3.1"
}

pub fn spdy_upgrade_response() -> &'static [u8] {
    concat!(
        "HTTP/1.1 101 Switching Protocols\r\n",
        "Connection: Upgrade\r\n",
        "Upgrade: SPDY/3.1\r\n",
        "X-Stream-Protocol-Version: portforward.k8s.io\r\n",
        "\r\n"
    )
    .as_bytes()
}

pub async fn serve(listen: &str) -> Result<(), String> {
    let listener = TcpListener::bind(listen).await.map_err(|e| e.to_string())?;
    eprintln!("krust-port-forward-bridge listening on {listen}");

    loop {
        let (socket, _) = listener.accept().await.map_err(|e| e.to_string())?;
        tokio::spawn(async move {
            if let Err(error) = handle_connection(socket).await {
                eprintln!("port-forward bridge connection failed: {error}");
            }
        });
    }
}

async fn handle_connection(mut socket: TcpStream) -> Result<(), String> {
    let request_head = read_http_request_head(&mut socket).await?;
    let raw = std::str::from_utf8(&request_head).map_err(|_| "HTTP request is not UTF-8")?;
    let request = parse_http_upgrade_request(raw)?;
    if !is_spdy_upgrade(&request) {
        socket
            .write_all(
                b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nexpected SPDY/3.1 upgrade\n",
            )
            .await
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    let bridge_request = parse_bridge_request(&request.path)?;
    socket
        .write_all(spdy_upgrade_response())
        .await
        .map_err(|e| e.to_string())?;
    run_spdy_port_forward_session(socket, bridge_request).await
}

async fn read_http_request_head(socket: &mut TcpStream) -> Result<Vec<u8>, String> {
    let mut buf = Vec::with_capacity(4096);
    let mut chunk = [0u8; 1024];
    loop {
        let n = socket.read(&mut chunk).await.map_err(|e| e.to_string())?;
        if n == 0 {
            return Err("connection closed before HTTP request completed".to_string());
        }
        buf.extend_from_slice(&chunk[..n]);
        if buf.windows(4).any(|window| window == b"\r\n\r\n") {
            return Ok(buf);
        }
        if buf.len() > 16 * 1024 {
            return Err("HTTP request head exceeds 16KiB".to_string());
        }
    }
}

fn parse_query(path: &str) -> (&str, HashMap<String, String>) {
    let Some((route, query)) = path.split_once('?') else {
        return (path, HashMap::new());
    };
    let params = query
        .split('&')
        .filter_map(|part| part.split_once('='))
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect();
    (route, params)
}

fn valid_target(target: &str) -> bool {
    target.parse::<IpAddr>().is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bridge_path_with_target_and_sorted_ports() {
        let request =
            parse_bridge_request("/portforward/pod-123?ports=8080,80&target=10.88.0.115").unwrap();

        assert_eq!(
            request,
            BridgeRequest {
                sandbox_id: "pod-123".to_string(),
                target: "10.88.0.115".to_string(),
                ports: vec![80, 8080],
            }
        );
    }

    #[test]
    fn rejects_missing_target() {
        let error = parse_bridge_request("/portforward/pod-123?ports=8080").unwrap_err();

        assert_eq!(error, "missing target");
    }

    #[test]
    fn rejects_non_ip_target() {
        let error =
            parse_bridge_request("/portforward/pod-123?ports=8080&target=example.com").unwrap_err();

        assert_eq!(error, "target must be an IP address");
    }

    #[test]
    fn parses_spdy_upgrade_request() {
        let raw = concat!(
            "POST /portforward/pod-123?ports=8080&target=10.88.0.115 HTTP/1.1\r\n",
            "Host: 127.0.0.1:10443\r\n",
            "Connection: Upgrade\r\n",
            "Upgrade: SPDY/3.1\r\n",
            "X-Stream-Protocol-Version: portforward.k8s.io\r\n",
            "\r\n"
        );
        let request = parse_http_upgrade_request(raw).unwrap();

        assert!(is_spdy_upgrade(&request));
        assert_eq!(request.method, "POST");
        assert_eq!(
            request.path,
            "/portforward/pod-123?ports=8080&target=10.88.0.115"
        );
    }

    #[test]
    fn spdy_upgrade_response_uses_kubernetes_stream_protocol_header() {
        let response = std::str::from_utf8(spdy_upgrade_response()).unwrap();

        assert!(response.starts_with("HTTP/1.1 101 Switching Protocols\r\n"));
        assert!(response.contains("Upgrade: SPDY/3.1\r\n"));
        assert!(response.contains("X-Stream-Protocol-Version: portforward.k8s.io\r\n"));
    }
}
