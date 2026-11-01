//go:build windows

package main

import (
	"golang.org/x/sys/windows"
	"path/filepath"
)

func isReparsePath(path string) bool {
	name, err := windows.UTF16PtrFromString(filepath.Clean(path))
	if err != nil {
		return true
	}
	attributes, err := windows.GetFileAttributes(name)
	return err != nil || attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0
}
