//! Address discovery for the QR payload / status / hello (`hosts`): the LAN
//! addresses, then the ones that also work away from it.

use std::net::Ipv4Addr;

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

/// 100.64.0.0/10: the addresses Tailscale gives its devices. They reach this
/// machine from any network the phone is on, as long as both run Tailscale.
fn is_tailscale(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    o[0] == 100 && (o[1] & 0xC0) == 64
}

/// This machine's Tailscale addresses (whatever the interface is called).
pub fn remote_hosts() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Ok(interfaces) = if_addrs::get_if_addrs() {
        for iface in interfaces {
            if iface.is_loopback() || !iface.is_oper_up() {
                continue;
            }
            if let IfAddr::V4(v4) = &iface.addr {
                let ip = v4.ip.to_string();
                if is_tailscale(v4.ip) && !out.contains(&ip) {
                    out.push(ip);
                }
            }
        }
    }
    out
}

/// Everything a phone may try, in this order: LAN addresses, Tailscale
/// addresses, then `extra` (config `extra_hosts`: other VPN addresses, DNS
/// names).
pub fn all_hosts(extra: &[String]) -> Vec<String> {
    let mut out = hosts();
    for host in remote_hosts().into_iter().chain(extra.iter().cloned()) {
        let host = host.trim().to_string();
        if !host.is_empty() && !out.contains(&host) {
            out.push(host);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tailscale_range() {
        assert!(is_tailscale(Ipv4Addr::new(100, 64, 0, 1)));
        assert!(is_tailscale(Ipv4Addr::new(100, 101, 102, 103)));
        assert!(is_tailscale(Ipv4Addr::new(100, 127, 255, 254)));
        assert!(!is_tailscale(Ipv4Addr::new(100, 63, 0, 1)));
        assert!(!is_tailscale(Ipv4Addr::new(100, 128, 0, 1)));
        assert!(!is_tailscale(Ipv4Addr::new(192, 168, 0, 64)));
    }

    #[test]
    fn extra_hosts_come_last_once() {
        let lan = hosts();
        let mut extra = vec![" mac.example.ts.net ".to_string(), String::new()];
        extra.extend(lan.first().cloned());
        let all = all_hosts(&extra);
        assert_eq!(all.iter().filter(|h| *h == "mac.example.ts.net").count(), 1);
        assert!(all.len() <= lan.len() + remote_hosts().len() + 1);
        assert_eq!(&all[..lan.len()], &lan[..]);
    }
}
