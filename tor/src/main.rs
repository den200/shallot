//! shallot-tor: a SOCKS5 proxy on 127.0.0.1 backed by Arti.
//!
//! Usage: `shallot-tor [port]` (default 9050).
//!
//! Status is reported on stdout, one line per event, for the menu-bar app:
//! `bootstrap <0-100>`, `ready`, and `error <message>` just before exiting 1.
//! The process exits on SIGTERM or when stdin reaches EOF, so it cannot
//! outlive the app that started it.

use std::error::Error;
use std::net::{Ipv4Addr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;

use arti_client::config::TorClientConfigBuilder;
use arti_client::TorClient;
use futures::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, StreamExt};
use tor_rtcompat::{
    NetStreamListener, NetStreamProvider, PreferredRuntime, SpawnExt, ToplevelBlockOn,
};
use tor_socksproto::{Buffer, Handshake, NextStep, SocksCmd, SocksProxyHandshake, SocksStatus};

type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;

fn main() {
    let port = std::env::args().nth(1).map_or(9050, |p| p.parse().expect("port"));

    std::thread::spawn(|| {
        let _ = std::io::copy(&mut std::io::stdin(), &mut std::io::sink());
        std::process::exit(0);
    });

    let rt = PreferredRuntime::create().expect("runtime");
    if let Err(e) = rt.block_on(run(rt.clone(), port)) {
        println!("error {e}");
        std::process::exit(1);
    }
}

async fn run(rt: PreferredRuntime, port: u16) -> Result<()> {
    // Loopback only, by design: there is no way to configure another address.
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let listener = rt.listen(&addr, &Default::default()).await?;

    let library = PathBuf::from(std::env::var("HOME")?).join("Library");
    let config = TorClientConfigBuilder::from_directories(
        library.join("Application Support/Shallot"),
        library.join("Caches/Shallot"),
    )
    .build()?;
    let client = TorClient::with_runtime(rt.clone())
        .config(config)
        .create_unbootstrapped()?;

    let mut events = client.bootstrap_events();
    rt.spawn(async move {
        while let Some(status) = events.next().await {
            if status.ready_for_traffic() {
                println!("ready");
            } else {
                println!("bootstrap {}", (status.as_frac() * 100.0) as u8);
            }
        }
    })?;
    client.bootstrap().await?;

    let mut incoming = listener.incoming();
    while let Some(conn) = incoming.next().await {
        let (stream, _) = conn?;
        let client = client.clone();
        rt.spawn(async move {
            let _ = serve(client, stream).await;
        })?;
    }
    Ok(())
}

async fn serve<S>(client: Arc<TorClient<PreferredRuntime>>, mut socks: S) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut handshake = SocksProxyHandshake::new();
    let mut buf = Buffer::new_precise();
    let request = loop {
        match handshake.step(&mut buf)? {
            NextStep::Send(data) => {
                socks.write_all(&data).await?;
                socks.flush().await?;
            }
            NextStep::Recv(mut recv) => {
                let n = socks.read(recv.buf()).await?;
                recv.note_received(n)?;
            }
            NextStep::Finished(done) => break done.into_output()?,
        }
    };

    if request.command() != SocksCmd::CONNECT {
        let reply = request.reply(SocksStatus::COMMAND_NOT_SUPPORTED, None)?;
        socks.write_all(&reply).await?;
        return Ok(());
    }

    let tor = match client
        .connect((request.addr().to_string(), request.port()))
        .await
    {
        Ok(tor) => tor,
        Err(e) => {
            let reply = request.reply(SocksStatus::GENERAL_FAILURE, None)?;
            socks.write_all(&reply).await?;
            return Err(e.into());
        }
    };
    socks
        .write_all(&request.reply(SocksStatus::SUCCEEDED, None)?)
        .await?;

    let (socks_r, socks_w) = socks.split();
    let (tor_r, tor_w) = tor.split();
    let _ = futures::join!(relay(socks_r, tor_w), relay(tor_r, socks_w));
    Ok(())
}

/// Copy until EOF, flushing after every read: an Arti stream holds written
/// bytes until it is flushed, so `futures::io::copy` would stall interactive
/// protocols.
async fn relay(
    mut from: impl AsyncRead + Unpin,
    mut to: impl AsyncWrite + Unpin,
) -> std::io::Result<()> {
    let mut buf = [0u8; 16 * 1024];
    loop {
        let n = from.read(&mut buf).await?;
        if n == 0 {
            return to.close().await;
        }
        to.write_all(&buf[..n]).await?;
        to.flush().await?;
    }
}
