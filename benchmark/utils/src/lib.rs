use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

pub struct PeakStats {
    pub peak_memory_mb: f64,
    pub peak_cpu_pct: f64,
}

// ─── Linux: /proc filesystem ───────────────────────────────────────────────

#[cfg(target_os = "linux")]
pub fn read_vm_rss_kb() -> u64 {
    read_vm_rss_kb_pid("self")
}

#[cfg(target_os = "linux")]
pub fn read_vm_rss_kb_pid(pid: &str) -> u64 {
    std::fs::read_to_string(format!("/proc/{}/status", pid))
        .unwrap_or_default()
        .lines()
        .find(|l| l.starts_with("VmRSS:"))
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

#[cfg(target_os = "linux")]
pub fn read_cpu_ticks() -> u64 {
    read_cpu_ticks_pid("self")
}

#[cfg(target_os = "linux")]
pub fn read_cpu_ticks_pid(pid: &str) -> u64 {
    let stat = std::fs::read_to_string(format!("/proc/{}/stat", pid)).unwrap_or_default();
    if let Some(pos) = stat.rfind(')') {
        let rest: Vec<&str> = stat[pos + 1..].split_whitespace().collect();
        let utime: u64 = rest.get(11).and_then(|s| s.parse().ok()).unwrap_or(0);
        let stime: u64 = rest.get(12).and_then(|s| s.parse().ok()).unwrap_or(0);
        utime + stime
    } else {
        0
    }
}

#[cfg(target_os = "linux")]
const TICKS_PER_SEC: f64 = 100.0;

// ─── macOS: getrusage ──────────────────────────────────────────────────────

#[cfg(target_os = "macos")]
pub fn read_vm_rss_kb() -> u64 {
    unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) == 0 {
            // macOS ru_maxrss is in bytes
            usage.ru_maxrss as u64 / 1024
        } else {
            0
        }
    }
}

#[cfg(target_os = "macos")]
pub fn read_vm_rss_kb_pid(_pid: &str) -> u64 {
    read_vm_rss_kb()
}

#[cfg(target_os = "macos")]
pub fn read_cpu_ticks() -> u64 {
    unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) == 0 {
            let utime =
                usage.ru_utime.tv_sec as u64 * 1_000_000 + usage.ru_utime.tv_usec as u64;
            let stime =
                usage.ru_stime.tv_sec as u64 * 1_000_000 + usage.ru_stime.tv_usec as u64;
            utime + stime
        } else {
            0
        }
    }
}

#[cfg(target_os = "macos")]
pub fn read_cpu_ticks_pid(_pid: &str) -> u64 {
    read_cpu_ticks()
}

#[cfg(target_os = "macos")]
const TICKS_PER_SEC: f64 = 1_000_000.0; // microseconds

// ─── Fallback ──────────────────────────────────────────────────────────────

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn read_vm_rss_kb() -> u64 { 0 }
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn read_vm_rss_kb_pid(_pid: &str) -> u64 { 0 }
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn read_cpu_ticks() -> u64 { 0 }
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn read_cpu_ticks_pid(_pid: &str) -> u64 { 0 }
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
const TICKS_PER_SEC: f64 = 1.0;

// ─── Monitor ───────────────────────────────────────────────────────────────

/// Spawn a background thread that samples peak RSS and peak CPU every 100 ms.
pub fn start_peak_monitor() -> (Arc<AtomicBool>, std::thread::JoinHandle<PeakStats>) {
    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = Arc::clone(&stop);

    let handle = std::thread::spawn(move || {
        let mut peak_mem_mb = 0f64;
        let mut peak_cpu_pct = 0f64;
        let ncpus = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1) as f64;

        let mut prev_ticks = read_cpu_ticks();
        let mut prev_time = Instant::now();

        while !stop_clone.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(100));

            let rss_mb = read_vm_rss_kb() as f64 / 1024.0;
            if rss_mb > peak_mem_mb {
                peak_mem_mb = rss_mb;
            }

            let curr_ticks = read_cpu_ticks();
            let curr_time = Instant::now();
            let elapsed = curr_time.duration_since(prev_time).as_secs_f64();
            let cpu_secs = curr_ticks.saturating_sub(prev_ticks) as f64 / TICKS_PER_SEC;
            let pct = if elapsed > 0.0 {
                (cpu_secs / elapsed / ncpus * 100.0).min(100.0 * ncpus)
            } else {
                0.0
            };
            if pct > peak_cpu_pct {
                peak_cpu_pct = pct;
            }

            prev_ticks = curr_ticks;
            prev_time = curr_time;
        }

        PeakStats {
            peak_memory_mb: peak_mem_mb,
            peak_cpu_pct,
        }
    });

    (stop, handle)
}

/// Like `start_peak_monitor`, but monitors an external process by PID.
pub fn start_peak_monitor_pid(pid: u32) -> (Arc<AtomicBool>, std::thread::JoinHandle<PeakStats>) {
    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = Arc::clone(&stop);
    let pid_str = pid.to_string();

    let handle = std::thread::spawn(move || {
        let mut peak_mem_mb = 0f64;
        let mut peak_cpu_pct = 0f64;
        let ncpus = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1) as f64;

        let mut prev_ticks = read_cpu_ticks_pid(&pid_str);
        let mut prev_time = Instant::now();

        while !stop_clone.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(100));

            let rss_mb = read_vm_rss_kb_pid(&pid_str) as f64 / 1024.0;
            if rss_mb > peak_mem_mb {
                peak_mem_mb = rss_mb;
            }

            let curr_ticks = read_cpu_ticks_pid(&pid_str);
            let curr_time = Instant::now();
            let elapsed = curr_time.duration_since(prev_time).as_secs_f64();
            let cpu_secs = curr_ticks.saturating_sub(prev_ticks) as f64 / TICKS_PER_SEC;
            let pct = if elapsed > 0.0 {
                (cpu_secs / elapsed / ncpus * 100.0).min(100.0 * ncpus)
            } else {
                0.0
            };
            if pct > peak_cpu_pct {
                peak_cpu_pct = pct;
            }

            prev_ticks = curr_ticks;
            prev_time = curr_time;
        }

        PeakStats {
            peak_memory_mb: peak_mem_mb,
            peak_cpu_pct,
        }
    });

    (stop, handle)
}
