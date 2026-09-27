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

pub fn is_excluded_iface(name: &str) -> bool {
    EXCLUDED_PREFIXES.iter().any(|p| name.starts_with(p))
}

/// IPv4 addresses of up, non-loopback, non-excluded interfaces (deduplicated,
/// enumeration order).
pub fn hosts() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
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
            if !out.contains(&ip) {
                out.push(ip);
            }
        }
    }
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
