//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

const (
	launcherClassName = "SchylerAIImage2Launcher"

	launcherInstallID = 1001
	launcherCheckID   = 1002
	launcherCancelID  = 1003

	wmCreate    = 0x0001
	wmDestroy   = 0x0002
	wmClose     = 0x0010
	wmCommand   = 0x0111
	wmAppStatus = 0x8001
	wmAppDone   = 0x8002
	wmAppExit   = 0x8003

	wsOverlappedWindow = 0x00CF0000
	wsVisible          = 0x10000000
	wsChild            = 0x40000000
	wsTabStop          = 0x00010000
	wsBorder           = 0x00800000
	wsExClientEdge     = 0x00000200
	wsExAppWindow      = 0x00040000

	esPassword    = 0x00000020
	esAutoHScroll = 0x00000080
	bsPushButton  = 0x00000000

	swShow = 5
)

var (
	user32                   = windows.NewLazySystemDLL("user32.dll")
	procRegisterClassExW     = user32.NewProc("RegisterClassExW")
	procCreateWindowExW      = user32.NewProc("CreateWindowExW")
	procDefWindowProcW       = user32.NewProc("DefWindowProcW")
	procDestroyWindow        = user32.NewProc("DestroyWindow")
	procDispatchMessageW     = user32.NewProc("DispatchMessageW")
	procEnableWindow         = user32.NewProc("EnableWindow")
	procGetMessageW          = user32.NewProc("GetMessageW")
	procGetWindowTextLengthW = user32.NewProc("GetWindowTextLengthW")
	procGetWindowTextW       = user32.NewProc("GetWindowTextW")
	procMessageBoxW          = user32.NewProc("MessageBoxW")
	procPostMessageW         = user32.NewProc("PostMessageW")
	procPostQuitMessage      = user32.NewProc("PostQuitMessage")
	procSetWindowTextW       = user32.NewProc("SetWindowTextW")
	procShowWindow           = user32.NewProc("ShowWindow")
	procTranslateMessage     = user32.NewProc("TranslateMessage")
	procUpdateWindow         = user32.NewProc("UpdateWindow")
	procGetModuleHandleW     = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetModuleHandleW")
)

type launcherWndClassEx struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     windows.Handle
	hIcon         windows.Handle
	hCursor       windows.Handle
	hbrBackground windows.Handle
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       windows.Handle
}

type launcherMsg struct {
	hwnd    windows.Handle
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	ptX     int32
	ptY     int32
	private uint32
}

type launcherEvent struct {
	text string
	done bool
}

type launcherWindow struct {
	hwnd           windows.Handle
	edit           windows.Handle
	geminiEdit     windows.Handle
	install        windows.Handle
	check          windows.Handle
	cancelButton   windows.Handle
	status         windows.Handle
	callbacks      LauncherCallbacks
	statusCh       chan launcherEvent
	completionCh   chan launcherEvent
	cancelMu       sync.Mutex
	cancelFunc     context.CancelFunc
	updateMu       sync.Mutex
	update         UpdateInfo
	busy           bool
	closeRequested bool
}

var (
	launcherWindowsMu sync.RWMutex
	launcherWindows   = make(map[windows.Handle]*launcherWindow)
	launcherPending   *launcherWindow
)

// ShowLauncher presents the small native Win32 launcher window and runs its
// message loop on the calling thread.
func ShowLauncher(version string, callbacks LauncherCallbacks) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	classPtr, err := windows.UTF16PtrFromString(launcherClassName)
	if err != nil {
		return errors.New("create launcher window class name failed")
	}
	instance, err := moduleHandle()
	if err != nil {
		return err
	}
	class := launcherWndClassEx{
		cbSize:        uint32(unsafe.Sizeof(launcherWndClassEx{})),
		lpfnWndProc:   windows.NewCallback(launcherWndProc),
		hInstance:     instance,
		lpszClassName: classPtr,
	}
	if result, _, callErr := procRegisterClassExW.Call(uintptr(unsafe.Pointer(&class))); result == 0 && callErr != windows.ERROR_CLASS_ALREADY_EXISTS {
		return errors.New("register launcher window class failed")
	}

	state := &launcherWindow{
		callbacks:    callbacks,
		statusCh:     make(chan launcherEvent, 64),
		completionCh: make(chan launcherEvent, 1),
	}
	launcherPending = state
	title, _ := windows.UTF16PtrFromString("SchylerAI Image2 MCP")
	hwnd, _, callErr := procCreateWindowExW.Call(
		wsExAppWindow,
		uintptr(unsafe.Pointer(classPtr)),
		uintptr(unsafe.Pointer(title)),
		wsOverlappedWindow,
		uintptr(0x80000000), uintptr(0x80000000), 520, 350,
		0, 0, uintptr(instance), 0,
	)
	launcherPending = nil
	if hwnd == 0 {
		if callErr != nil {
			return fmt.Errorf("create launcher window failed: %w", callErr)
		}
		return errors.New("create launcher window failed")
	}
	state.hwnd = windows.Handle(hwnd)
	launcherWindowsMu.Lock()
	launcherWindows[state.hwnd] = state
	launcherWindowsMu.Unlock()
	createLauncherControls(state, version)
	procShowWindow.Call(hwnd, swShow)
	procUpdateWindow.Call(hwnd)

	var message launcherMsg
	for {
		result, _, callErr := procGetMessageW.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0)
		if int32(result) == -1 {
			return fmt.Errorf("launcher message loop failed: %w", callErr)
		}
		if result == 0 {
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&message)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&message)))
	}
	return nil
}

func moduleHandle() (windows.Handle, error) {
	result, _, callErr := procGetModuleHandleW.Call(0)
	if result == 0 {
		return 0, fmt.Errorf("get launcher module handle failed: %w", callErr)
	}
	return windows.Handle(result), nil
}

func createLauncherControls(state *launcherWindow, version string) {
	state.createControl("STATIC", "至少填写一个密钥；留空的服务将保持未配置。", wsVisible|wsChild, 24, 12, 460, 20, 0)
	state.createControl("STATIC", "Image2 API 密钥（选填）", wsVisible|wsChild, 24, 40, 460, 20, 0)
	state.edit = state.createControl("EDIT", "", wsVisible|wsChild|wsTabStop|wsBorder|esPassword|esAutoHScroll, 24, 62, 460, 28, 0)
	state.createControl("STATIC", "Gemini API 密钥（选填）", wsVisible|wsChild, 24, 104, 460, 20, 0)
	state.geminiEdit = state.createControl("EDIT", "", wsVisible|wsChild|wsTabStop|wsBorder|esPassword|esAutoHScroll, 24, 126, 460, 28, 0)
	state.install = state.createControl("BUTTON", "安装 / 更新密钥", wsVisible|wsChild|wsTabStop|bsPushButton, 24, 172, 145, 32, launcherInstallID)
	state.check = state.createControl("BUTTON", "检查更新", wsVisible|wsChild|wsTabStop|bsPushButton, 184, 172, 145, 32, launcherCheckID)
	state.cancelButton = state.createControl("BUTTON", "取消", wsVisible|wsChild|wsTabStop|bsPushButton, 344, 172, 140, 32, launcherCancelID)
	state.status = state.createControl("STATIC", "内置版本："+version, wsVisible|wsChild, 24, 226, 460, 60, 0)
	state.setBusy(false)
}

func (state *launcherWindow) createControl(className, text string, style uint32, x, y, width, height int, id uintptr) windows.Handle {
	classPtr, _ := windows.UTF16PtrFromString(className)
	textPtr, _ := windows.UTF16PtrFromString(text)
	hwnd, _, _ := procCreateWindowExW.Call(
		func() uintptr {
			if className == "EDIT" {
				return wsExClientEdge
			}
			return 0
		}(),
		uintptr(unsafe.Pointer(classPtr)), uintptr(unsafe.Pointer(textPtr)), uintptr(style),
		uintptr(x), uintptr(y), uintptr(width), uintptr(height), uintptr(state.hwnd), id, 0, 0,
	)
	return windows.Handle(hwnd)
}

func launcherWndProc(hwnd, message, wParam, lParam uintptr) uintptr {
	state := launcherWindowFor(windows.Handle(hwnd))
	switch uint32(message) {
	case wmCommand:
		if state != nil {
			switch uint16(wParam & 0xffff) {
			case launcherInstallID:
				state.installOrUpdate()
			case launcherCheckID:
				state.checkForUpdate()
			case launcherCancelID:
				state.cancelOperation()
			}
		}
	case wmAppStatus:
		if state != nil {
			select {
			case event := <-state.statusCh:
				state.setStatus(event.text)
				if event.done {
					state.setBusy(false)
				}
			default:
			}
		}
	case wmAppDone:
		if state != nil {
			select {
			case event := <-state.completionCh:
				state.setStatus(event.text)
				state.setBusy(false)
				state.updateButtonLabel()
				if state.closeRequested {
					procDestroyWindow.Call(hwnd)
				}
			default:
			}
		}
	case wmAppExit:
		if state != nil {
			state.setBusy(false)
		}
		procDestroyWindow.Call(hwnd)
	case wmClose:
		if state != nil && state.busy {
			state.closeRequested = true
			state.cancelOperation()
			return 0
		}
		procDestroyWindow.Call(hwnd)
	case wmDestroy:
		if state != nil {
			state.cancelOperation()
			launcherWindowsMu.Lock()
			delete(launcherWindows, windows.Handle(hwnd))
			launcherWindowsMu.Unlock()
		}
		procPostQuitMessage.Call(0)
	default:
		result, _, _ := procDefWindowProcW.Call(hwnd, message, wParam, lParam)
		return result
	}
	return 0
}

func launcherWindowFor(hwnd windows.Handle) *launcherWindow {
	launcherWindowsMu.RLock()
	defer launcherWindowsMu.RUnlock()
	if launcherPending != nil && launcherPending.hwnd == hwnd {
		return launcherPending
	}
	return launcherWindows[hwnd]
}

func readKeyControl(control windows.Handle) string {
	length, _, _ := procGetWindowTextLengthW.Call(uintptr(control))
	if length == 0 {
		return ""
	}
	buffer := make([]uint16, length+1)
	procGetWindowTextW.Call(uintptr(control), uintptr(unsafe.Pointer(&buffer[0])), length+1)
	key := windows.UTF16ToString(buffer)
	for index := range buffer {
		buffer[index] = 0
	}
	return key
}

func (state *launcherWindow) setStatus(text string) {
	textPtr, _ := windows.UTF16PtrFromString(text)
	procSetWindowTextW.Call(uintptr(state.status), uintptr(unsafe.Pointer(textPtr)))
}

func (state *launcherWindow) postEvent(event launcherEvent) {
	if event.done {
		select {
		case state.completionCh <- event:
		default:
			// A completion is expected once per operation. Replacing an
			// unconsumed completion keeps the UI recoverable without blocking
			// an installer goroutine after its window has been closed.
			select {
			case <-state.completionCh:
			default:
			}
			select {
			case state.completionCh <- event:
			default:
			}
		}
		procPostMessageW.Call(uintptr(state.hwnd), wmAppDone, 0, 0)
		return
	}
	select {
	case state.statusCh <- event:
		procPostMessageW.Call(uintptr(state.hwnd), wmAppStatus, 0, 0)
	default:
	}
}

func (state *launcherWindow) setBusy(busy bool) {
	state.busy = busy
	procEnableWindow.Call(uintptr(state.install), boolToUintptr(!busy))
	procEnableWindow.Call(uintptr(state.check), boolToUintptr(!busy))
	procEnableWindow.Call(uintptr(state.cancelButton), boolToUintptr(busy))
}

func boolToUintptr(value bool) uintptr {
	if value {
		return 1
	}
	return 0
}

func (state *launcherWindow) installOrUpdate() {
	if state.busy {
		return
	}
	credentials := InstallerCredentials{Image2Key: readKeyControl(state.edit), GeminiKey: readKeyControl(state.geminiEdit)}
	if err := credentials.Validate(); err != nil {
		state.setStatus(err.Error())
		return
	}
	procSetWindowTextW.Call(uintptr(state.edit), 0)
	procSetWindowTextW.Call(uintptr(state.geminiEdit), 0)
	if state.callbacks.Install == nil {
		state.setStatus(launcherOperationError(errInstallerCallbacksUnavailable))
		return
	}
	state.runOperation(func(ctx context.Context) (string, error) {
		err := state.callbacks.Install(ctx, credentials, func(output string) {
			state.postEvent(launcherEvent{text: launcherInstallerStatus(output)})
		})
		return "安装已验证。请重启 Codex 或新建会话。", err
	})
}

func (state *launcherWindow) checkForUpdate() {
	if state.busy {
		return
	}
	state.updateMu.Lock()
	update := state.update
	state.updateMu.Unlock()
	if update.Available && state.callbacks.ApplyUpdate != nil {
		state.runOperation(func(ctx context.Context) (string, error) {
			return "", state.callbacks.ApplyUpdate(ctx, update)
		})
		return
	}
	if state.callbacks.CheckUpdate == nil {
		state.setStatus("更新检查暂不可用。")
		return
	}
	state.runOperation(func(ctx context.Context) (string, error) {
		info, err := state.callbacks.CheckUpdate(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return "", ctx.Err()
			}
			return "", errors.New("Update check failed. You can still install the embedded version.")
		}
		state.updateMu.Lock()
		state.update = info
		state.updateMu.Unlock()
		if !info.Available {
			return "当前已是最新版本。", nil
		}
		return "发现新版本：" + info.Version + "。" + info.Notes, nil
	})
}

func (state *launcherWindow) updateButtonLabel() {
	state.updateMu.Lock()
	available := state.update.Available && state.callbacks.ApplyUpdate != nil
	state.updateMu.Unlock()
	label := "检查更新"
	if available {
		label = "下载新版本"
	}
	ptr, _ := windows.UTF16PtrFromString(label)
	procSetWindowTextW.Call(uintptr(state.check), uintptr(unsafe.Pointer(ptr)))
}

func (state *launcherWindow) runOperation(operation func(context.Context) (string, error)) {
	state.cancelMu.Lock()
	ctx, cancel := context.WithCancel(context.Background())
	state.cancelFunc = cancel
	state.cancelMu.Unlock()
	state.setBusy(true)
	state.postEvent(launcherEvent{text: "正在处理，请稍候…"})
	go func() {
		message, err := operation(ctx)
		cancel()
		if errors.Is(err, errUpdateLaunched) {
			procPostMessageW.Call(uintptr(state.hwnd), wmAppExit, 0, 0)
			return
		}
		if err != nil {
			state.postEvent(launcherEvent{text: launcherOperationError(err), done: true})
			return
		}
		state.postEvent(launcherEvent{text: message, done: true})
	}()
}

func (state *launcherWindow) cancelOperation() {
	state.cancelMu.Lock()
	cancel := state.cancelFunc
	state.cancelMu.Unlock()
	if cancel != nil {
		cancel()
		state.postEvent(launcherEvent{text: "已请求取消。已开始的安装会在完成或回滚后关闭。"})
	}
}

func showLauncherMessage(title, message string) {
	titlePtr, _ := windows.UTF16PtrFromString(title)
	messagePtr, _ := windows.UTF16PtrFromString(message)
	procMessageBoxW.Call(0, uintptr(unsafe.Pointer(messagePtr)), uintptr(unsafe.Pointer(titlePtr)), 0x00000010)
}
