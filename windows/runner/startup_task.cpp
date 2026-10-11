#include "startup_task.h"

#include <appmodel.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.h>

#include <memory>
#include <string>
#include <thread>

namespace startup_task {
namespace {

// Must match msix_config.startup_task.task_id in pubspec.yaml.
constexpr wchar_t kTaskId[] = L"DoseDropStartup";

using Channel = flutter::MethodChannel<flutter::EncodableValue>;
using Result = flutter::MethodResult<flutter::EncodableValue>;

// A method call travelling to the worker thread and back.
struct Pending {
  std::unique_ptr<Result> result;
  std::string state;
};

std::unique_ptr<Channel> g_channel;
HWND g_window = nullptr;

bool HasPackageIdentity() {
  UINT32 length = 0;
  return ::GetCurrentPackageFullName(&length, nullptr) !=
         APPMODEL_ERROR_NO_PACKAGE;
}

std::string StateName(winrt::Windows::ApplicationModel::StartupTaskState s) {
  using winrt::Windows::ApplicationModel::StartupTaskState;
  switch (s) {
    case StartupTaskState::Enabled:
      return "enabled";
    case StartupTaskState::Disabled:
      return "disabled";
    case StartupTaskState::DisabledByUser:
      return "disabledByUser";
    case StartupTaskState::DisabledByPolicy:
      return "disabledByPolicy";
    case StartupTaskState::EnabledByPolicy:
      return "enabledByPolicy";
  }
  return "unknown";
}

// Runs on a worker thread, never the UI thread: the calls block on async
// WinRT operations.
std::string Run(const std::string& method) {
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    using winrt::Windows::ApplicationModel::StartupTask;
    StartupTask task = StartupTask::GetAsync(kTaskId).get();
    if (method == "enable") {
      // Desktop apps get no prompt. A task the user switched off in
      // Settings > Apps > Startup stays off and reports disabledByUser.
      return StateName(task.RequestEnableAsync().get());
    }
    if (method == "disable") {
      task.Disable();
    }
    return StateName(task.State());
  } catch (const winrt::hresult_error& error) {
    return "error:" + winrt::to_string(error.message());
  }
}

}  // namespace

void Register(flutter::BinaryMessenger* messenger, HWND window) {
  g_window = window;
  g_channel = std::make_unique<Channel>(
      messenger, "dosedrop/startup_task",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<Result> result) {
        const std::string method = call.method_name();
        if (method != "getState" && method != "enable" &&
            method != "disable") {
          result->NotImplemented();
          return;
        }
        if (!HasPackageIdentity()) {
          result->Success(flutter::EncodableValue("unpackaged"));
          return;
        }
        auto* pending = new Pending{std::move(result), std::string()};
        HWND target = g_window;
        std::thread([pending, method, target]() {
          pending->state = Run(method);
          if (!::PostMessage(target, kResultMessage, 0,
                             reinterpret_cast<LPARAM>(pending))) {
            // The window is gone and the engine with it: drop the result
            // without touching it from this thread.
            static_cast<void>(pending->result.release());
            delete pending;
          }
        }).detach();
      });
}

bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != kResultMessage) {
    return false;
  }
  std::unique_ptr<Pending> pending(reinterpret_cast<Pending*>(lparam));
  if (pending->state.rfind("error:", 0) == 0) {
    pending->result->Error("startup_task", pending->state.substr(6));
  } else {
    pending->result->Success(flutter::EncodableValue(pending->state));
  }
  return true;
}

}  // namespace startup_task
