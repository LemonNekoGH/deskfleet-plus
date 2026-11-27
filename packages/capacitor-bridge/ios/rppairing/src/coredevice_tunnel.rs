//! CoreDevice tunnel establishment over LocalDevVPN (`10.7.0.1`).
//!
//! Supports both:
//! - Legacy lockdown pairing files (`PairingFile`, iOS 17–26) via `CoreDeviceProxy` (`62078`).
//! - iOS 27+ RemotePairing files (`RpPairingFile`) via direct `RpPairingSocket` (`49152`),
//!   falling back to untrusted RSD + `RemoteXpcClient`, then TLS-PSK `CDTunnel`.

use std::net::IpAddr;

use idevice::core_device_proxy::CoreDeviceProxy;
use idevice::pairing_file::PairingFile;
use idevice::provider::TcpProvider;
use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use idevice::tcp::handle::AdapterHandle;
use idevice::{IdeviceService, RemoteXpcClient};
use tokio::net::TcpStream;

const REMOTE_PAIRING_PORT: u16 = 49152;

async fn open_coredevice_rsd_via_lockdown(
    addr: IpAddr,
    pairing_file: PairingFile,
) -> Result<(AdapterHandle, RsdHandshake), String> {
    let provider = TcpProvider {
        addr,
        pairing_file,
        label: "deskfleet-plus".to_string(),
        scope_id: None,
    };
    let proxy = CoreDeviceProxy::connect(&provider)
        .await
        .map_err(|e| format!("CoreDeviceProxy connect to {addr} failed: {e}"))?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy
        .create_software_tunnel()
        .map_err(|e| format!("CoreDevice software tunnel failed: {e}"))?
        .to_async_handle();
    let stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| format!("CoreDevice RSD connect on port {rsd_port} failed: {e}"))?;
    let handshake = RsdHandshake::new(stream)
        .await
        .map_err(|e| format!("CoreDevice RSD handshake failed: {e}"))?;
    Ok((adapter, handshake))
}

async fn finish_tls_psk_cd_tunnel(
    addr: IpAddr,
    tunnel_port: u16,
    encryption_key: &[u8],
) -> Result<(AdapterHandle, RsdHandshake), String> {
    let tunnel_stream = TcpStream::connect((addr, tunnel_port))
        .await
        .map_err(|e| format!("Failed to connect to TLS-PSK tunnel on {addr}:{tunnel_port}: {e}"))?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, encryption_key)
        .await
        .map_err(|e| format!("CDTunnel TLS-PSK handshake failed: {e}"))?;

    let client_ip: IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|e| format!("Invalid CDTunnel client IP '{}': {e}", tunnel.info.client_address))?;
    let server_ip: IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|e| format!("Invalid CDTunnel server IP '{}': {e}", tunnel.info.server_address))?;
    let mtu = (tunnel.info.mtu as usize).clamp(576, 8192);
    let rsd_port = tunnel.info.server_rsd_port;

    let mut raw_adapter = Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    raw_adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = raw_adapter.to_async_handle();

    let stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|e| format!("Trusted RSD connect on port {rsd_port} failed: {e}"))?;
    let handshake = RsdHandshake::new(stream)
        .await
        .map_err(|e| format!("Trusted RSD handshake failed: {e}"))?;
    Ok((adapter, handshake))
}

async fn open_coredevice_rsd_via_remote_pairing_direct(
    addr: IpAddr,
    mut rpf: RpPairingFile,
) -> Result<(AdapterHandle, RsdHandshake), String> {
    let stream = TcpStream::connect((addr, REMOTE_PAIRING_PORT))
        .await
        .map_err(|e| format!("Failed to connect to RemotePairing on {addr}:{REMOTE_PAIRING_PORT}: {e}"))?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "DeskFleet Plus");
    rpc.connect(&mut rpf, async || String::new())
        .await
        .map_err(|e| format!("Direct RemotePairing pair-verify failed: {e}"))?;
    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|e| format!("Direct RemotePairing create_tcp_listener failed: {e}"))?;
    finish_tls_psk_cd_tunnel(addr, tunnel_port, rpc.encryption_key()).await
}

async fn open_coredevice_rsd_via_remote_pairing_xpc(
    addr: IpAddr,
    mut rpf: RpPairingFile,
) -> Result<(AdapterHandle, RsdHandshake), String> {
    let rsd_conn = TcpStream::connect((addr, REMOTE_PAIRING_PORT))
        .await
        .map_err(|e| format!("Failed to connect to untrusted RSD on {addr}:{REMOTE_PAIRING_PORT}: {e}"))?;
    let untrusted_rsd = RsdHandshake::new(rsd_conn)
        .await
        .map_err(|e| format!("Untrusted RSD handshake on {addr}:{REMOTE_PAIRING_PORT} failed: {e}"))?;
    let tunnel_svc = untrusted_rsd
        .services
        .get("com.apple.internal.dt.coredevice.untrusted.tunnelservice")
        .ok_or_else(|| {
            "Device RSD missing com.apple.internal.dt.coredevice.untrusted.tunnelservice".to_string()
        })?;

    let ts_stream = TcpStream::connect((addr, tunnel_svc.port))
        .await
        .map_err(|e| {
            format!(
                "Failed to connect to untrusted tunnelservice on {addr}:{}: {e}",
                tunnel_svc.port
            )
        })?;
    let mut xpc = RemoteXpcClient::new(ts_stream)
        .await
        .map_err(|e| format!("RemoteXPC client init failed: {e}"))?;
    xpc.do_handshake()
        .await
        .map_err(|e| format!("RemoteXPC handshake failed: {e}"))?;
    let _ = xpc
        .recv_root()
        .await
        .map_err(|e| format!("RemoteXPC root recv failed: {e}"))?;

    let mut rpc = RemotePairingClient::new(xpc, "DeskFleet Plus");
    rpc.connect(&mut rpf, async || String::new())
        .await
        .map_err(|e| format!("RemoteXPC RemotePairing pair-verify failed: {e}"))?;
    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|e| format!("RemoteXPC RemotePairing create_tcp_listener failed: {e}"))?;
    finish_tls_psk_cd_tunnel(addr, tunnel_port, rpc.encryption_key()).await
}

async fn open_coredevice_rsd_via_remote_pairing(
    addr: IpAddr,
    rpf: RpPairingFile,
) -> Result<(AdapterHandle, RsdHandshake), String> {
    // On LocalDevVPN / CalicoMeow (10.7.0.1:49152), port 49152 speaks direct RpPairingSocket;
    // fall back to untrusted RSD + RemoteXPC tunnelservice if needed.
    match open_coredevice_rsd_via_remote_pairing_direct(addr, rpf.clone()).await {
        Ok(res) => Ok(res),
        Err(direct_err) => match open_coredevice_rsd_via_remote_pairing_xpc(addr, rpf).await {
            Ok(res) => Ok(res),
            Err(xpc_err) => Err(format!("{direct_err}; xpc fallback: {xpc_err}")),
        },
    }
}

pub(crate) async fn open_coredevice_rsd(
    host_ip: &str,
    pairing_path: &str,
) -> Result<(AdapterHandle, RsdHandshake), String> {
    let addr: IpAddr = host_ip
        .trim()
        .parse()
        .map_err(|e| format!("Invalid CoreDevice host IP '{host_ip}': {e}"))?;

    // Try standard lockdown pairingFile.plist first (iOS 17–26 / idevice_pair / SideStore),
    // then fall back to iOS 27+ RemotePairing RpPairingFile (on-device pairing).
    if let Ok(pairing_file) = PairingFile::read_from_file(pairing_path) {
        return open_coredevice_rsd_via_lockdown(addr, pairing_file).await;
    }
    if let Ok(rpf) = RpPairingFile::read_from_file(pairing_path).await {
        return open_coredevice_rsd_via_remote_pairing(addr, rpf).await;
    }

    Err(format!(
        "Failed to parse pairing file at '{pairing_path}' as either a lockdown PairingFile or an iOS 27 RemotePairing RpPairingFile."
    ))
}
