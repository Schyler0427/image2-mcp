//go:build windows

package main

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// nativeSystemInfo mirrors the prefix and scalar fields of SYSTEM_INFO used by
// GetNativeSystemInfo. The API writes the native machine architecture even
// when this launcher is running as a 32-bit process under WOW64.
type nativeSystemInfo struct {
	ProcessorArchitecture uint16
	Reserved              uint16
	PageSize              uint32
	MinimumApplication    uintptr
	MaximumApplication    uintptr
	ActiveProcessorMask   uintptr
	NumberOfProcessors    uint32
	ProcessorType         uint32
	AllocationGranularity uint32
	ProcessorLevel        uint16
	ProcessorRevision     uint16
}

var procGetNativeSystemInfo = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetNativeSystemInfo")

// NativeArchitecture returns the operating system architecture, independent
// of the architecture of the launcher process itself.
func NativeArchitecture() (string, error) {
	var info nativeSystemInfo
	procGetNativeSystemInfo.Call(uintptr(unsafe.Pointer(&info)))
	arch, err := architectureFromProcessorArchitecture(info.ProcessorArchitecture)
	if err != nil {
		return "", fmt.Errorf("read native Windows architecture: %w", err)
	}
	return arch, nil
}
