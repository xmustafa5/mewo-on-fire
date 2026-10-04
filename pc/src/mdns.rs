//! mDNS advertisement of `_ccnotify._tcp.local.` (instance = hostname,
//! TXT id=<pc_id>). Failure is logged and never fatal.

use std::collections::HashMap;

use anyhow::{anyhow, Result};
use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};

use crate::config::Config;
use crate::net;

pub const SERVICE_TYPE: &str = "_ccnotify._tcp.local.";

pub fn advertise(cfg: &Config) -> Option<ServiceDaemon> {
    match try_advertise(cfg) {
        Ok(daemon) => {
            eprintln!(
                "mewo: mDNS advertising \"{}\" as {} on port {}",
                cfg.name, SERVICE_TYPE, cfg.port
            );
            Some(daemon)
        }
        Err(e) => {
            eprintln!(
                "mewo: warning: mDNS advertisement failed ({e:#}); continuing without discovery"
            );
            None
        }
    }
}

pub fn shutdown(daemon: Option<ServiceDaemon>) {
    if let Some(d) = daemon {
        let _ = d.shutdown();
    }
}

/// DNS-label-safe version of the hostname for the SRV target host.
fn host_label(s: &str) -> String {
    // Keep the whole label ("ccnotify-<label>-<16 hex>") under 63 bytes.
    let label: String = s
        .chars()
        .take(30)
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
        .collect();
    let label = label.trim_matches('-').to_string();
    if label.is_empty() {
        "pc".to_string()
    } else {
        label
    }
}

fn try_advertise(cfg: &Config) -> Result<ServiceDaemon> {
    let daemon = ServiceDaemon::new().map_err(|e| anyhow!("starting mDNS daemon: {e}"))?;

    // Only advertise IPv4 on real LAN interfaces (hosts in the QR are IPv4 too).
    let _ = daemon.disable_interface(IfKind::IPv6);
    let excluded: Vec<IfKind> = net::excluded_iface_names()
        .into_iter()
        .map(IfKind::Name)
        .collect();
    if !excluded.is_empty() {
        let _ = daemon.disable_interface(excluded);
    }

    // Use a dedicated SRV host name so we never clash with avahi's own
    // `<hostname>.local` records.
    let host = format!(
        "ccnotify-{}-{}.local.",
        host_label(&cfg.name).to_ascii_lowercase(),
        cfg.pc_id
    );
    let mut props: HashMap<String, String> = HashMap::new();
    props.insert("id".to_string(), cfg.pc_id.clone());

    let info = ServiceInfo::new(SERVICE_TYPE, &cfg.name, &host, "", cfg.port, props)
        .map_err(|e| anyhow!("building mDNS service info: {e}"))?
        .enable_addr_auto();
    daemon
        .register(info)
        .map_err(|e| anyhow!("registering mDNS service: {e}"))?;
    Ok(daemon)
}
