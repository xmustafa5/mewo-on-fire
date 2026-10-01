//! LAN address discovery for the QR payload / status (`hosts`).

use if_addrs::IfAddr;

/// Interface name prefixes that never carry the phone's LAN.
pub const EXCLUDED_PREFIXES: &[&str] = &[
    "docker",
    "br-",
    "veth",
    "virbr",
    "lxc",
    "tun",
    "tailscale",
    "wg",
];

/// macOS: VPN tunnels (also Tailscale / WireGuard), AirDrop / peer-to-peer
/// Wi-Fi, and VM host-only networks.
#[cfg(target_os = "macos")]
const MACOS_EXCLUDED_PREFIXES: &[&str] = &["utun", "awdl", "llw", "anpi", "vmnet"];

pub fn is_excluded_iface(name: &str) -> bool {
    #[cfg(target_os = "macos")]
    if MACOS_EXCLUDED_PREFIXES.iter().any(|p| name.starts_with(p)) {
        return true;
    }
    EXCLUDED_PREFIXES.iter().any(|p| name.starts_with(p))
}

/// macOS `bridge*` interfaces are mostly VM networks (the phone cannot reach
/// them), but Internet Sharing uses one too: kept, tried after the others.
fn is_last_resort_iface(name: &str) -> bool {
    cfg!(target_os = "macos") && name.starts_with("bridge")
}

/// IPv4 addresses of up, non-loopback, non-excluded interfaces (deduplicated,
/// enumeration order; macOS bridges last).
pub fn hosts() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut last_resort: Vec<String> = Vec::new();
    let interfaces = match if_addrs::get_if_addrs() {
        Ok(i) => i,
        Err(_) => return out,
    };
    for iface in interfaces {
        if iface.is_loopback() || !iface.is_oper_up() || is_excluded_iface(&iface.name) {
            continue;
        }
        if let IfAddr::V4(v4) = &iface.addr {
            let ip = v4.ip.to_string();
            if out.contains(&ip) || last_resort.contains(&ip) {
                continue;
            }
            if is_last_resort_iface(&iface.name) {
                last_resort.push(ip);
            } else {
                out.push(ip);
            }
        }
    }
    out.append(&mut last_resort);
    out
}

/// Names of currently present interfaces matching the exclusion list.
pub fn excluded_iface_names() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Ok(interfaces) = if_addrs::get_if_addrs() {
        for iface in interfaces {
            if is_excluded_iface(&iface.name) && !out.contains(&iface.name) {
                out.push(iface.name);
            }
        }
    }
    out
}
