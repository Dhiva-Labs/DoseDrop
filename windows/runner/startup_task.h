#ifndef RUNNER_STARTUP_TASK_H_
#define RUNNER_STARTUP_TASK_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// "Start DoseDrop at login" for the Microsoft Store (MSIX) build.
//
// Inside an MSIX package the HKCU Run key that launch_at_startup writes is
// virtualized, so Windows never sees it. The package instead declares a
// windows.startupTask extension (msix_config.startup_task in pubspec.yaml)
// and the app switches it on and off through the WinRT StartupTask API.
//
// Method channel "dosedrop/startup_task", methods getState / enable /
// disable. Each answers with the resulting state: "unpackaged" (no package
// identity, so the caller should keep using the Run key), "enabled",
// "disabled", "disabledByUser", "enabledByPolicy" or "disabledByPolicy".
//
// The WinRT calls run on a worker thread. Their answer is posted back to the
// window as kResultMessage and delivered on the platform thread by
// HandleMessage.
namespace startup_task {

constexpr UINT kResultMessage = WM_APP + 0x51;

// Installs the channel. |window| receives kResultMessage.
void Register(flutter::BinaryMessenger* messenger, HWND window);

// Returns true when |message| was a startup task result and has been
// delivered to Dart.
bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

}  // namespace startup_task

#endif  // RUNNER_STARTUP_TASK_H_
