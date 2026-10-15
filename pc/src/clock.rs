//! v2.7: the local clock and the work hours. The build autopilot starts
//! nothing outside them; what runs finishes.

use serde_json::{json, Value};

/// Local `(weekday 1 = Monday … 7 = Sunday, hour, minute)`.
pub fn local_now() -> (u8, u8, u8) {
    let t = unsafe { libc::time(std::ptr::null_mut()) };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&t, &mut tm) };
    let wday = if tm.tm_wday == 0 { 7 } else { tm.tm_wday as u8 };
    (wday, tm.tm_hour as u8, tm.tm_min as u8)
}

/// `"09:00-18:00"` → `(540, 1080)` minutes; None when empty or malformed.
pub fn parse_hours(hours: &str) -> Option<(u16, u16)> {
    let (a, b) = hours.trim().split_once('-')?;
    let m = |s: &str| -> Option<u16> {
        let (h, mi) = s.trim().split_once(':')?;
        Some(h.parse::<u16>().ok()? * 60 + mi.parse::<u16>().ok()?)
    };
    let (a, b) = (m(a)?, m(b)?);
    if a < b && b <= 24 * 60 {
        Some((a, b))
    } else {
        None
    }
}

/// Inside the work hours now? Always, when none are set.
pub fn within(hours: &str, days: &[u8]) -> bool {
    let (wday, h, mi) = local_now();
    if !days.is_empty() && !days.contains(&wday) {
        return false;
    }
    match parse_hours(hours) {
        Some((a, b)) => {
            let now = h as u16 * 60 + mi as u16;
            now >= a && now < b
        }
        None => true,
    }
}

/// When the work hours next open, in ms since the epoch: now when they
/// are open or not set, else the next day's start.
pub fn next_start(hours: &str, days: &[u8]) -> u64 {
    let now_ms = crate::config::now_ms();
    if within(hours, days) {
        return now_ms;
    }
    let Some((a, _)) = parse_hours(hours).or(Some((9 * 60, 18 * 60))) else { return now_ms };
    let (wday, h, mi) = local_now();
    let now_min = h as u32 * 60 + mi as u32;
    for ahead in 0..8u32 {
        let day = ((wday as u32 - 1 + ahead) % 7 + 1) as u8;
        if !days.is_empty() && !days.contains(&day) {
            continue;
        }
        if ahead == 0 && now_min >= a as u32 {
            continue;
        }
        let delta_min = ahead * 24 * 60 + a as u32 - if ahead == 0 { now_min } else { now_min };
        let delta = if ahead == 0 { a as i64 - now_min as i64 } else { (ahead * 24 * 60) as i64 + a as i64 - now_min as i64 };
        let _ = delta_min;
        return now_ms + (delta.max(0) as u64) * 60 * 1000;
    }
    now_ms + 24 * 60 * 60 * 1000
}

/// With the configured hours.
pub fn within_now() -> bool {
    let (h, d) = crate::config::work_hours();
    within(&h, &d)
}

pub fn describe_now() -> Value {
    let (h, d) = crate::config::work_hours();
    describe(&h, &d)
}

pub fn describe(hours: &str, days: &[u8]) -> Value {
    json!({"hours": hours, "days": days, "within": within(hours, days), "next_start": next_start(hours, days)})
}
