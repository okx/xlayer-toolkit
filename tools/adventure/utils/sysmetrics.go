package utils

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// SysMetrics holds a point-in-time snapshot of system-wide resource utilization.
type SysMetrics struct {
	// CPU utilization in percent (0–100), system-wide across all cores.
	CPUPercent float64
	// Memory utilization in percent (0–100).
	MemPercent float64
	// Total physical memory in bytes.
	MemTotalBytes uint64
	// Used physical memory in bytes (MemTotal - MemAvailable).
	MemUsedBytes uint64
	// Aggregate disk read throughput since last sample, bytes/s.
	DiskReadBytesPerSec float64
	// Aggregate disk write throughput since last sample, bytes/s.
	DiskWriteBytesPerSec float64
}

// cpuStat holds raw values read from /proc/stat for a single sample.
type cpuStat struct {
	user    uint64
	nice    uint64
	system  uint64
	idle    uint64
	iowait  uint64
	irq     uint64
	softirq uint64
	steal   uint64
}

func (s cpuStat) total() uint64 {
	return s.user + s.nice + s.system + s.idle + s.iowait + s.irq + s.softirq + s.steal
}

func (s cpuStat) busy() uint64 {
	return s.total() - s.idle - s.iowait
}

// diskStat holds the read/write sector counts for a single block device from /proc/diskstats.
type diskStat struct {
	readSectors  uint64
	writeSectors uint64
}

// SysMetricsCollector samples system metrics across consecutive calls, computing
// deltas between samples to derive utilization rates.
type SysMetricsCollector struct {
	prevCPU      cpuStat
	prevDisk     map[string]diskStat
	prevDiskTime time.Time
}

// NewSysMetricsCollector creates a collector and records an initial baseline sample
// so the first call to Sample returns meaningful deltas.
func NewSysMetricsCollector() *SysMetricsCollector {
	c := &SysMetricsCollector{
		prevDisk: make(map[string]diskStat),
	}
	// Prime the baseline; errors here are non-fatal.
	c.prevCPU, _ = readCPUStat()
	c.prevDisk, c.prevDiskTime = readDiskStats()
	return c
}

// Sample reads current system stats, computes deltas against the previous sample,
// and returns a populated SysMetrics. It is safe to call from a single goroutine.
func (c *SysMetricsCollector) Sample() SysMetrics {
	var m SysMetrics

	// --- CPU ---
	cur, err := readCPUStat()
	if err == nil {
		deltaBusy := float64(cur.busy() - c.prevCPU.busy())
		deltaTotal := float64(cur.total() - c.prevCPU.total())
		if deltaTotal > 0 {
			m.CPUPercent = 100.0 * deltaBusy / deltaTotal
		}
		c.prevCPU = cur
	}

	// --- Memory ---
	m.MemTotalBytes, m.MemUsedBytes, m.MemPercent, _ = readMemInfo()

	// --- Disk I/O ---
	curDisk, curDiskTime := readDiskStats()
	elapsedSec := curDiskTime.Sub(c.prevDiskTime).Seconds()
	if elapsedSec > 0 {
		var totalReadSectors, totalWriteSectors uint64
		for dev, cs := range curDisk {
			ps := c.prevDisk[dev]
			totalReadSectors += cs.readSectors - ps.readSectors
			totalWriteSectors += cs.writeSectors - ps.writeSectors
		}
		// Linux sector size is 512 bytes.
		m.DiskReadBytesPerSec = float64(totalReadSectors) * 512.0 / elapsedSec
		m.DiskWriteBytesPerSec = float64(totalWriteSectors) * 512.0 / elapsedSec
	}
	c.prevDisk = curDisk
	c.prevDiskTime = curDiskTime

	return m
}

// FormatConsole returns a compact human-readable string for console output.
func (m SysMetrics) FormatConsole() string {
	return fmt.Sprintf(
		"CPU: %5.1f%% | Mem: %5.1f%% (%s / %s) | Disk R/W: %s/s / %s/s",
		m.CPUPercent,
		m.MemPercent,
		formatBytes(m.MemUsedBytes),
		formatBytes(m.MemTotalBytes),
		formatBytes(uint64(m.DiskReadBytesPerSec)),
		formatBytes(uint64(m.DiskWriteBytesPerSec)),
	)
}

// formatBytes converts a byte count to a human-readable IEC string (KiB, MiB, GiB).
func formatBytes(b uint64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%dB", b)
	}
	div, exp := uint64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f%ciB", float64(b)/float64(div), "KMGTPE"[exp])
}

// readCPUStat parses the first "cpu" aggregate line from /proc/stat.
func readCPUStat() (cpuStat, error) {
	f, err := os.Open("/proc/stat")
	if err != nil {
		return cpuStat{}, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "cpu ") {
			continue
		}
		fields := strings.Fields(line)
		// fields[0] = "cpu", then user nice system idle iowait irq softirq steal ...
		if len(fields) < 9 {
			break
		}
		nums := make([]uint64, 8)
		for i := 0; i < 8; i++ {
			nums[i], _ = strconv.ParseUint(fields[i+1], 10, 64)
		}
		return cpuStat{
			user:    nums[0],
			nice:    nums[1],
			system:  nums[2],
			idle:    nums[3],
			iowait:  nums[4],
			irq:     nums[5],
			softirq: nums[6],
			steal:   nums[7],
		}, nil
	}
	return cpuStat{}, fmt.Errorf("cpu line not found in /proc/stat")
}

// readMemInfo parses /proc/meminfo and returns (total, used, usedPercent, error).
func readMemInfo() (total, used uint64, pct float64, err error) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return
	}
	defer f.Close()

	var memTotal, memAvailable uint64
	found := 0
	scanner := bufio.NewScanner(f)
	for scanner.Scan() && found < 2 {
		line := scanner.Text()
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		val, _ := strconv.ParseUint(fields[1], 10, 64)
		switch fields[0] {
		case "MemTotal:":
			memTotal = val * 1024 // kB → bytes
			found++
		case "MemAvailable:":
			memAvailable = val * 1024
			found++
		}
	}
	total = memTotal
	if memTotal > memAvailable {
		used = memTotal - memAvailable
	}
	if memTotal > 0 {
		pct = 100.0 * float64(used) / float64(memTotal)
	}
	return
}

// readDiskStats parses /proc/diskstats and returns per-device sector counts along
// with the current time for elapsed-time calculation.
func readDiskStats() (map[string]diskStat, time.Time) {
	now := time.Now()
	result := make(map[string]diskStat)

	f, err := os.Open("/proc/diskstats")
	if err != nil {
		return result, now
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		// /proc/diskstats fields (0-indexed):
		//  0: major, 1: minor, 2: name,
		//  3: reads_completed, 4: reads_merged, 5: sectors_read, 6: time_reading_ms
		//  7: writes_completed, 8: writes_merged, 9: sectors_written, 10: time_writing_ms
		if len(fields) < 10 {
			continue
		}
		name := fields[2]
		// Skip partition entries (e.g. sda1, nvme0n1p1); keep whole-disk devices.
		if isPartition(name) {
			continue
		}
		var ds diskStat
		ds.readSectors, _ = strconv.ParseUint(fields[5], 10, 64)
		ds.writeSectors, _ = strconv.ParseUint(fields[9], 10, 64)
		result[name] = ds
	}
	return result, now
}

// isPartition returns true if the device name looks like a partition rather than
// a whole disk (e.g. sda1, nvme0n1p2) so we avoid double-counting.
func isPartition(name string) bool {
	if len(name) == 0 {
		return false
	}
	last := name[len(name)-1]
	if last < '0' || last > '9' {
		return false
	}
	// nvme devices use the form nvme0n1 (whole disk) vs nvme0n1p1 (partition).
	if strings.Contains(name, "nvme") {
		return strings.Contains(name, "p")
	}
	// For sd*, vd*, hd*, xvd* etc. a trailing digit means partition.
	return true
}
