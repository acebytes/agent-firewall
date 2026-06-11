//go:build unix

package main

import (
	"fmt"
	"os"
	"syscall"
)

// checkSocketPerms enforces the security contract:
//
//   - path must exist
//   - must be a socket
//   - must be owned by the same UID as the running shim
//   - mode (permission) bits must be exactly 0600
//
// Returns an error if any check fails. Shim's caller converts any error into
// exit 2 (fail-closed).
func checkSocketPerms(path string) error {
	fi, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("socket %s: %w", path, err)
	}
	if fi.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("socket %s: not a socket", path)
	}
	stat, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("socket %s: cannot stat syscall info", path)
	}
	if int(stat.Uid) != os.Geteuid() {
		return fmt.Errorf("socket %s: owner uid %d ≠ shim uid %d", path, stat.Uid, os.Geteuid())
	}
	perm := fi.Mode().Perm()
	if perm != 0o600 {
		return fmt.Errorf("socket %s: mode %o ≠ 0600", path, perm)
	}
	return nil
}
