package main

import (
	"context"
	"errors"
	"strconv"
	"strings"
)

// Installer output is diagnostic text, so only known progress messages are
// presented in the GUI. Unknown output never becomes a user-visible error.
func launcherInstallerStatus(output string) string {
	switch strings.TrimSpace(output) {
	case "Checking public Release...":
		return "正在检查发布版本…"
	case "Downloading source package...":
		return "正在下载安装包…"
	case "Preparing installation...":
		return "正在准备安装…"
	case "Installing platform binary...":
		return "正在安装平台程序…"
	case "Verifying local installation...":
		return "正在验证本地安装…"
	case "Verification: OK":
		return "本地安装验证通过。"
	case "API Key configured (not displayed).":
		return "API 密钥已配置。"
	case "Transaction cleanup failed; evidence retained.":
		return "安装事务清理失败，已保留排查记录。"
	}
	for _, prefix := range []string{"Retained transaction evidence:", "Retained failed target evidence:", "Retained backup evidence:"} {
		if strings.HasPrefix(output, prefix) {
			return "已保留安装事务记录，供排查问题。"
		}
	}
	if strings.HasPrefix(output, "Previous installation retained at:") {
		return "已保留原有安装备份。"
	}
	return "正在安装，请稍候…"
}

var launcherErrorTranslations = map[string]string{
	"launcher installer is unavailable":                                "安装功能暂不可用。",
	"embedded installer is unavailable":                                "内置安装功能暂不可用。",
	"installer payload directory is required":                          "安装包目录不可用。",
	"create installer input pipe failed":                               "创建安装输入通道失败。",
	"start installer failed":                                           "启动安装程序失败",
	"attach installer process job failed":                              "无法管理安装进程，请重试。",
	"installer failed":                                                 "安装失败，请重试。",
	"send installer key failed":                                        "向安装程序发送密钥失败。",
	"close installer input failed":                                     "关闭安装输入通道失败。",
	"resume installer process failed":                                  "无法继续运行安装程序。",
	"create launcher workspace failed":                                 "创建安装临时目录失败。",
	"Update check failed. You can still install the embedded version.": "更新检查失败。仍可安装内置版本。",
	"no launcher update is available":                                  "暂无可用的启动器更新。",
	"native Windows architecture is unsupported":                       "暂不支持此 Windows 架构。",
	"launcher update does not support this Windows architecture":       "此更新不支持当前 Windows 架构。",
	"launcher update directory is unavailable":                         "更新目录不可用。",
	"start downloaded launcher failed":                                 "启动新版启动器失败。",
	"download update failed":                                           "下载更新失败，请重试。",
	"read update download failed":                                      "读取更新文件失败，请重试。",
	"downloaded update size does not match manifest":                   "更新文件大小校验失败，请重试。",
	"downloaded update sha256 does not match manifest":                 "更新文件完整性校验失败，请重试。",
	"flush downloaded update failed":                                   "保存更新文件失败。",
	"close downloaded update failed":                                   "保存更新文件失败。",
	"verified update already exists with different contents":           "已有更新文件内容不同，请清理更新缓存后重试。",
	"inspect existing verified update failed":                          "无法读取已有更新文件。",
	"retain verified update failed":                                    "保留已验证的更新文件失败。",
	"create launcher window class name failed":                         "创建启动器窗口失败。",
	"register launcher window class failed":                            "注册启动器窗口失败。",
	"create launcher window failed":                                    "创建启动器窗口失败。",
}

// Keep system, download, and installer diagnostics out of the native status
// control. The exit code is safe to retain and helps identify failed installs.
func launcherOperationError(err error) string {
	if errors.Is(err, context.Canceled) {
		return "操作已取消。"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "操作超时，请重试。"
	}
	if err == nil {
		return "操作失败，请重试。"
	}
	message := err.Error()
	if strings.HasPrefix(message, "安装失败（退出代码 ") && strings.HasSuffix(message, "）") {
		value := strings.TrimSuffix(strings.TrimPrefix(message, "安装失败（退出代码 "), "）")
		if code, parseErr := strconv.Atoi(value); parseErr == nil {
			return installerFailureMessage(code)
		}
	}
	if translated, ok := launcherErrorTranslations[message]; ok {
		return translated
	}
	for _, translated := range launcherErrorTranslations {
		if message == translated {
			return translated
		}
	}
	for _, prefix := range []string{"embedded ", "payload ", "unsupported payload ", "unsupported Windows "} {
		if strings.HasPrefix(message, prefix) {
			return "内置安装包校验失败，请重新下载启动器。"
		}
	}
	for _, prefix := range []string{"create launcher window failed:", "launcher message loop failed:", "get launcher module handle failed:"} {
		if strings.HasPrefix(message, prefix) {
			return "启动器窗口发生错误，请重新打开。"
		}
	}
	if strings.HasPrefix(message, "read native Windows architecture:") || strings.HasPrefix(message, "unsupported native Windows processor architecture ") {
		return "无法识别或暂不支持当前 Windows 架构。"
	}
	if strings.Contains(message, "update") {
		return "更新失败，无法验证或保存新版本。请重试。"
	}
	return "操作失败，请重试。"
}
