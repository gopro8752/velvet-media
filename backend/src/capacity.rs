//! Lightweight server capacity signals. All values are observed, not estimates:
//! unavailable platform/container counters stay null. Call on the same cadence
//! as the pool snapshot; CPU utilization is the delta in cumulative seconds
//! divided by elapsed wall time (100% is one CPU core).

use std::path::Path;

use serde::Serialize;

#[derive(Debug, Clone, Default, Serialize)]
pub struct HostMetricsSnapshot {
    /// CPU time of the Velvet backend process only, excluding child encoders.
    pub cpu_seconds: Option<f64>,
    pub cpu_available_cores: Option<u64>,
    /// Finite container CPU quota; absent when unrestricted or unsupported.
    pub cpu_limit_cores: Option<f64>,
    /// CPU time of the cgroup including child processes, when cgroup v2 exposes it.
    pub cgroup_cpu_seconds: Option<f64>,
    pub rss_bytes: Option<u64>,
    pub memory_total_bytes: Option<u64>,
    pub memory_available_bytes: Option<u64>,
    /// Finite cgroup memory limit. Host physical memory is reported separately.
    pub memory_limit_bytes: Option<u64>,
    pub cgroup_memory_bytes: Option<u64>,
    /// Space available to this process on the filesystem containing storage_path.
    pub disk_free_bytes: Option<u64>,
    pub disk_total_bytes: Option<u64>,
}

/// Point `storage_path` at the configured database or its data directory. This
/// reads procfs/statvfs directly and never shells out or reads provider secrets.
pub fn host_metrics_snapshot(storage_path: &Path) -> HostMetricsSnapshot {
    let mut result = HostMetricsSnapshot {
        cpu_available_cores: std::thread::available_parallelism().ok().map(|n| n.get() as u64),
        ..Default::default()
    };
    process_usage(&mut result);
    linux_memory_and_cgroup(&mut result);
    disk_usage(storage_path, &mut result);
    result
}

#[cfg(unix)]
fn process_usage(result: &mut HostMetricsSnapshot) {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    // SAFETY: getrusage initializes the entire output on success; no pointer
    // escapes this call and the uninitialized value is never read on failure.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } == 0 {
        let usage = unsafe { usage.assume_init() };
        result.cpu_seconds = Some(
            usage.ru_utime.tv_sec as f64 + usage.ru_utime.tv_usec as f64 / 1_000_000.0
                + usage.ru_stime.tv_sec as f64 + usage.ru_stime.tv_usec as f64 / 1_000_000.0,
        );
        // ru_maxrss is a high-water mark, not current RSS. Do not relabel it as
        // current resident memory; Linux /proc/self/status provides that below.
    }
}

#[cfg(not(unix))]
fn process_usage(_result: &mut HostMetricsSnapshot) {}

#[cfg(target_os = "linux")]
fn linux_memory_and_cgroup(result: &mut HostMetricsSnapshot) {
    if let Ok(status) = std::fs::read_to_string("/proc/self/status") {
        result.rss_bytes = kib_value(&status, "VmRSS:");
    }
    if let Ok(memory) = std::fs::read_to_string("/proc/meminfo") {
        result.memory_total_bytes = kib_value(&memory, "MemTotal:");
        result.memory_available_bytes = kib_value(&memory, "MemAvailable:");
    }
    // In a container cgroup namespace this is normally "/"; outside a
    // namespace, resolve the process's v2 membership under the standard mount.
    // A missing/nonstandard/v1 mount stays unknown rather than reporting zero.
    let membership = std::fs::read_to_string("/proc/self/cgroup").ok()
        .and_then(|text| text.lines().find_map(|line| line.strip_prefix("0::").map(str::to_owned)));
    if let Some(membership) = membership {
        let relative = Path::new(membership.trim_start_matches('/'));
        // Avoid walking outside the cgroup filesystem for unusual namespace
        // paths containing "..". The root counters may describe other processes.
        if relative.components().any(|part| matches!(part, std::path::Component::ParentDir)) { return; }
        let directory = Path::new("/sys/fs/cgroup").join(relative);
        let read = |name: &str| std::fs::read_to_string(directory.join(name)).ok();
        result.cpu_limit_cores = read("cpu.max").as_deref().and_then(cpu_quota);
        result.memory_limit_bytes = read("memory.max").as_deref().and_then(finite_limit);
        result.cgroup_memory_bytes = read("memory.current").as_deref().and_then(finite_limit);
        result.cgroup_cpu_seconds = read("cpu.stat").and_then(|text| {
            text.lines().find_map(|line| {
                let mut fields = line.split_whitespace();
                if fields.next()? != "usage_usec" { return None; }
                fields.next()?.parse::<u64>().ok().map(|micros| micros as f64 / 1_000_000.0)
            })
        });
    }
}

#[cfg(not(target_os = "linux"))]
fn linux_memory_and_cgroup(_result: &mut HostMetricsSnapshot) {}

#[cfg(any(target_os = "linux", test))]
fn kib_value(contents: &str, name: &str) -> Option<u64> {
    contents.lines().find_map(|line| {
        let mut fields = line.split_whitespace();
        if fields.next()? != name { return None; }
        let value = fields.next()?.parse::<u64>().ok()?;
        if fields.next()? != "kB" { return None; }
        value.checked_mul(1024)
    })
}

#[cfg(any(target_os = "linux", test))]
fn finite_limit(contents: &str) -> Option<u64> {
    let value = contents.trim().parse::<u64>().ok()?;
    // cgroup v1 uses huge sentinel values; treating those as available capacity
    // would be misleading if these helpers ever encounter one.
    (value < (1u64 << 60)).then_some(value)
}

#[cfg(any(target_os = "linux", test))]
fn cpu_quota(contents: &str) -> Option<f64> {
    let mut fields = contents.split_whitespace();
    let quota = fields.next()?.parse::<u64>().ok()?;
    let period = fields.next()?.parse::<u64>().ok()?;
    if quota == 0 || period == 0 { return None; }
    Some(quota as f64 / period as f64)
}

#[cfg(unix)]
fn disk_usage(storage_path: &Path, result: &mut HostMetricsSnapshot) {
    use std::os::unix::ffi::OsStrExt;
    // Configuration may point to a database not created yet. Its nearest
    // existing ancestor still identifies the correct data filesystem.
    let absolute = if storage_path.is_absolute() { storage_path.to_path_buf() }
        else if let Ok(directory) = std::env::current_dir() { directory.join(storage_path) }
        else { return; };
    let Some(path) = absolute.ancestors().find(|path| path.exists()) else { return; };
    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else { return; };
    let mut usage = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: CString is NUL-terminated and lives through the call. statvfs
    // initializes the output on success; it is never read after an error.
    if unsafe { libc::statvfs(path.as_ptr(), usage.as_mut_ptr()) } == 0 {
        let usage = unsafe { usage.assume_init() };
        let block_size = usage.f_frsize as u64;
        result.disk_free_bytes = (usage.f_bavail as u64).checked_mul(block_size);
        result.disk_total_bytes = (usage.f_blocks as u64).checked_mul(block_size);
    }
}

#[cfg(not(unix))]
fn disk_usage(_storage_path: &Path, _result: &mut HostMetricsSnapshot) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_unlimited_cgroup_capacity_is_unknown() {
        assert_eq!(finite_limit("max\n"), None);
        assert_eq!(finite_limit("9223372036854771712\n"), None);
        assert_eq!(finite_limit("536870912\n"), Some(536_870_912));
        assert_eq!(cpu_quota("max 100000\n"), None);
        assert_eq!(cpu_quota("200000 100000\n"), Some(2.0));
        assert_eq!(cpu_quota("50000 100000\n"), Some(0.5));
        assert_eq!(cpu_quota("100000 0"), None);
    }

    #[test]
    fn procfs_memory_units_are_explicit_and_overflow_safe() {
        let text = "MemTotal:       16384 kB\nMemAvailable:  8192 kB\nVmRSS: 400 kB\n";
        assert_eq!(kib_value(text, "VmRSS:"), Some(409600));
        assert_eq!(kib_value(text, "MemTotal:"), Some(16777216));
        assert_eq!(kib_value(text, "Missing:"), None);
        assert_eq!(kib_value("VmRSS: 800 MB", "VmRSS:"), None);
        assert_eq!(kib_value("VmRSS: 18446744073709551615 kB", "VmRSS:"), None);
    }

    #[test]
    fn platform_snapshot_has_real_disk_and_cpu_or_null() {
        let snapshot = host_metrics_snapshot(&std::env::temp_dir());
        #[cfg(unix)] {
            assert!(snapshot.cpu_seconds.unwrap() >= 0.0);
            assert!(snapshot.disk_total_bytes.unwrap() > 0);
            assert!(snapshot.disk_free_bytes.unwrap() <= snapshot.disk_total_bytes.unwrap());
        }
        let json = serde_json::to_value(snapshot).unwrap();
        assert!(json.get("memory_limit_bytes").is_some(), "unknown metrics must be explicit nulls");
    }
}
