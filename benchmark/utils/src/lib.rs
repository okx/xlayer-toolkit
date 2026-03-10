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

/// Kernel-tracked peak RSS (VmHWM). Updated on every page fault, not sampled.
#[cfg(target_os = "linux")]
pub fn read_peak_rss_kb() -> u64 {
    read_peak_rss_kb_pid("self")
}

#[cfg(target_os = "linux")]
pub fn read_peak_rss_kb_pid(pid: &str) -> u64 {
    std::fs::read_to_string(format!("/proc/{}/status", pid))
        .unwrap_or_default()
        .lines()
        .find(|l| l.starts_with("VmHWM:"))
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

// ─── macOS: Mach task_info + getrusage ────────────────────────────────────

/// Current resident size via Mach task_info (physical pages currently mapped).
/// Does not include compressed pages or clean file-backed pages that were evicted.
#[cfg(target_os = "macos")]
pub fn read_vm_rss_kb() -> u64 {
    #[allow(non_camel_case_types)]
    type mach_port_t = u32;
    #[allow(non_camel_case_types)]
    type kern_return_t = i32;
    #[allow(non_camel_case_types)]
    type task_flavor_t = u32;
    #[allow(non_camel_case_types)]
    type task_info_t = *mut i32;
    #[allow(non_camel_case_types)]
    type mach_msg_type_number_t = u32;

    const MACH_TASK_BASIC_INFO: task_flavor_t = 20;

    #[repr(C)]
    #[allow(non_camel_case_types)]
    struct mach_task_basic_info {
        virtual_size: u64,
        resident_size: u64,
        resident_size_max: u64,
        user_time: [i32; 2],
        system_time: [i32; 2],
        policy: i32,
        suspend_count: i32,
    }

    extern "C" {
        fn mach_task_self() -> mach_port_t;
        fn task_info(
            target_task: mach_port_t,
            flavor: task_flavor_t,
            task_info_out: task_info_t,
            task_info_outCnt: *mut mach_msg_type_number_t,
        ) -> kern_return_t;
    }

    unsafe {
        let mut info: mach_task_basic_info = std::mem::zeroed();
        let mut count = (std::mem::size_of::<mach_task_basic_info>()
            / std::mem::size_of::<i32>()) as mach_msg_type_number_t;
        let kr = task_info(
            mach_task_self(),
            MACH_TASK_BASIC_INFO,
            &mut info as *mut _ as task_info_t,
            &mut count,
        );
        if kr == 0 {
            info.resident_size / 1024
        } else {
            0
        }
    }
}

#[cfg(target_os = "macos")]
pub fn read_vm_rss_kb_pid(_pid: &str) -> u64 {
    // macOS: cannot read another process's RSS without entitlements
    read_vm_rss_kb()
}

#[cfg(target_os = "macos")]
pub fn read_peak_rss_kb() -> u64 {
    // Unused on macOS — monitor uses polled max instead.
    // Kept for API compatibility.
    read_vm_rss_kb()
}

#[cfg(target_os = "macos")]
pub fn read_peak_rss_kb_pid(_pid: &str) -> u64 {
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
pub fn read_peak_rss_kb() -> u64 { 0 }
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn read_peak_rss_kb_pid(_pid: &str) -> u64 { 0 }
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn read_cpu_ticks() -> u64 { 0 }
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn read_cpu_ticks_pid(_pid: &str) -> u64 { 0 }
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
const TICKS_PER_SEC: f64 = 1.0;

// ─── Monitor ───────────────────────────────────────────────────────────────

/// Spawn a background thread that samples RSS and CPU every 100 ms.
///
/// - Linux: uses VmHWM (kernel-tracked peak, no sampling gaps)
/// - macOS: polls current RSS via Mach task_info and tracks the max during
///   the monitoring window only, avoiding ru_maxrss lifetime-max issues.
pub fn start_peak_monitor() -> (Arc<AtomicBool>, std::thread::JoinHandle<PeakStats>) {
    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = Arc::clone(&stop);

    let handle = std::thread::spawn(move || {
        let mut peak_rss_kb: u64 = 0;
        let mut peak_cpu_pct = 0f64;
        let ncpus = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1) as f64;

        let mut prev_ticks = read_cpu_ticks();
        let mut prev_time = Instant::now();

        while !stop_clone.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(100));

            // Sample current RSS
            let current_rss_kb = read_vm_rss_kb();
            if current_rss_kb > peak_rss_kb {
                peak_rss_kb = current_rss_kb;
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

        // On Linux, VmHWM catches spikes between samples — use max of both.
        #[cfg(target_os = "linux")]
        {
            let hwm_kb = read_peak_rss_kb();
            if hwm_kb > peak_rss_kb {
                peak_rss_kb = hwm_kb;
            }
        }

        let peak_mem_mb = peak_rss_kb as f64 / 1024.0;

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
        let mut peak_rss_kb: u64 = 0;
        let mut peak_cpu_pct = 0f64;
        let ncpus = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1) as f64;

        let mut prev_ticks = read_cpu_ticks_pid(&pid_str);
        let mut prev_time = Instant::now();

        while !stop_clone.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(100));

            let current_rss_kb = read_vm_rss_kb_pid(&pid_str);
            if current_rss_kb > peak_rss_kb {
                peak_rss_kb = current_rss_kb;
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

        #[cfg(target_os = "linux")]
        {
            let hwm_kb = read_peak_rss_kb_pid(&pid_str);
            if hwm_kb > peak_rss_kb {
                peak_rss_kb = hwm_kb;
            }
        }

        let peak_mem_mb = peak_rss_kb as f64 / 1024.0;

        PeakStats {
            peak_memory_mb: peak_mem_mb,
            peak_cpu_pct,
        }
    });

    (stop, handle)
}
