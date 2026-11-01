//go:build windows

package main

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// RunInstaller starts the embedded offline installer. Both keys are written once
// to PowerShell's redirected standard input and are never included in process
// arguments, the child environment, or status output.
func RunInstaller(ctx context.Context, payloadDir string, credentials InstallerCredentials, onOutput func(string)) error {
	if err := credentials.Validate(); err != nil {
		return err
	}
	credentials = credentials.normalized()
	if payloadDir == "" {
		return errors.New("installer payload directory is required")
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}
	if onOutput == nil {
		onOutput = func(string) {}
	}

	scriptPath := filepath.Join(payloadDir, "install-offline.ps1")
	// Do not use CommandContext: killing PowerShell after it starts can bypass
	// the bootstrap catch/finally block and leave half-committed installation.
	command := exec.Command("powershell.exe",
		"-NoLogo", "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-File", scriptPath)
	command.WaitDelay = installerStreamDrainTimeout
	command.Dir = payloadDir
	command.Env = installerEnvironment(credentials.Secrets())
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.CREATE_NO_WINDOW | windows.CREATE_SUSPENDED,
	}
	stdin, err := command.StdinPipe()
	if err != nil {
		return errors.New("create installer input pipe failed")
	}
	stdout := newInstallerOutputWriter(credentials.Secrets(), onOutput)
	stderr := newInstallerOutputWriter(credentials.Secrets(), onOutput)
	command.Stdout = stdout
	command.Stderr = stderr
	if err := command.Start(); err != nil {
		_ = stdin.Close()
		return errors.New("start installer failed")
	}
	job, err := newInstallerJob(command.Process.Pid)
	if err != nil {
		_ = command.Process.Kill()
		_ = command.Wait()
		_ = stdin.Close()
		return errors.New("attach installer process job failed")
	}
	finish := func() error {
		waitErr := command.Wait()
		// Closing a kill-on-close job after the top-level process exits also
		// closes any descendant PowerShell processes still holding output pipes.
		job.close()
		stdout.Discard()
		stderr.Discard()
		if waitErr != nil {
			var exitErr *exec.ExitError
			if errors.As(waitErr, &exitErr) {
				return errors.New(installerFailureMessage(exitErr.ExitCode()))
			}
			return errors.New("installer failed")
		}
		return nil
	}
	// The installer consumes two lines through redirected stdin. Closing the
	// pipe before resume makes pipe/cancellation failures safe: no child code
	// can yet have changed the installation or Codex configuration.
	if _, err := io.WriteString(stdin, credentials.Stdin()); err != nil {
		_ = stdin.Close()
		job.close()
		_ = finish()
		return errors.New("send installer key failed")
	}
	if err := stdin.Close(); err != nil {
		job.close()
		_ = finish()
		return errors.New("close installer input failed")
	}
	return runInstallerTransaction(ctx, func() error {
		if err := resumeInstallerPrimaryThread(uint32(command.Process.Pid)); err != nil {
			return errors.New("resume installer process failed")
		}
		return nil
	}, finish, job.close)
}

const installerStreamDrainTimeout = 5 * time.Second

type installerJob struct {
	handle windows.Handle
	once   sync.Once
}

func newInstallerJob(pid int) (*installerJob, error) {
	handle, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	job := &installerJob{handle: handle}
	var limits windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(handle, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		job.close()
		return nil, err
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(pid))
	if err != nil {
		job.close()
		return nil, err
	}
	err = windows.AssignProcessToJobObject(handle, process)
	_ = windows.CloseHandle(process)
	if err != nil {
		job.close()
		return nil, err
	}
	return job, nil
}

func resumeInstallerPrimaryThread(pid uint32) error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ThreadEntry32{Size: uint32(unsafe.Sizeof(windows.ThreadEntry32{}))}
	if err := windows.Thread32First(snapshot, &entry); err != nil {
		return err
	}
	for {
		if entry.OwnerProcessID == pid {
			thread, err := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, entry.ThreadID)
			if err != nil {
				return err
			}
			_, resumeErr := windows.ResumeThread(thread)
			_ = windows.CloseHandle(thread)
			return resumeErr
		}
		err := windows.Thread32Next(snapshot, &entry)
		if err == windows.ERROR_NO_MORE_FILES {
			break
		}
		if err != nil {
			return err
		}
	}
	return errors.New("installer primary thread not found")
}

func (job *installerJob) close() {
	if job == nil {
		return
	}
	job.once.Do(func() { _ = windows.CloseHandle(job.handle) })
}

func installerEnvironment(secrets []string) []string {
	entries := os.Environ()
	filtered := make([]string, 0, len(entries))
	for _, entry := range entries {
		name, _, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		lowerName := strings.ToLower(name)
		// Remove known credential variables and any value containing the key.
		containsSecret := false
		for _, secret := range secrets {
			if secret != "" && strings.Contains(entry, secret) {
				containsSecret = true
			}
		}
		if strings.Contains(lowerName, "api_key") || containsSecret {
			continue
		}
		filtered = append(filtered, entry)
	}
	return filtered
}
