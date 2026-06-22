package utils

import (
	"log"
	"strconv"
	"strings"
)

// ReadAccountsFromFile reads an accounts file (one private key / address per line) and applies
// the configured AccountOffset, a half-open range "start:end" — i.e. it returns indices
// [start, end). For example "0:4000" yields accounts 0..3999. An empty AccountOffset returns
// every line.
//
// Both `*-init` (which funds accounts) and `*-bench` (which sends from them) load accounts through
// this function, so the same slice is funded and benched — e.g. `gasless-init`/`gasless-bench` with
// "0:1000" set up and drive accounts 0..999, while `erc20-init`/`erc20-bench` with "1000:5000" use
// 1000..4999. Keep the init and bench AccountOffset identical (same config) so funded == benched.
//
// A malformed or out-of-range AccountOffset is a configuration error and aborts, since silently
// using the wrong account set would produce misleading benchmark results.
func ReadAccountsFromFile(filepath string) []string {
	lines := ReadDataFromFile(filepath)

	spec := strings.TrimSpace(TransferCfg.AccountOffset)
	if spec == "" {
		return lines
	}

	parts := strings.SplitN(spec, ":", 2)
	if len(parts) != 2 {
		log.Fatalf("invalid accountOffset %q: expected \"start:end\" (half-open range [start,end))", spec)
	}
	start, errStart := strconv.Atoi(strings.TrimSpace(parts[0]))
	end, errEnd := strconv.Atoi(strings.TrimSpace(parts[1]))
	if errStart != nil || errEnd != nil {
		log.Fatalf("invalid accountOffset %q: start and end must be integers", spec)
	}
	if start < 0 || end < start || end > len(lines) {
		log.Fatalf("accountOffset %q out of range: need 0 <= start <= end <= %d (file has %d accounts)",
			spec, len(lines), len(lines))
	}

	log.Printf("🔢 accountOffset %q applied: using accounts [%d, %d) of %d\n", spec, start, end, len(lines))
	return lines[start:end]
}
