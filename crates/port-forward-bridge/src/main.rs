use std::net::SocketAddr;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listen = std::env::args()
        .collect::<Vec<_>>()
        .windows(2)
        .find_map(|window| (window[0] == "--listen").then(|| window[1].clone()))
        .unwrap_or_else(|| "127.0.0.1:10443".to_string());
    let _addr: SocketAddr = listen.parse()?;
    krust_port_forward_bridge::bridge::serve(&listen)
        .await
        .map_err(|error| error.into())
}
