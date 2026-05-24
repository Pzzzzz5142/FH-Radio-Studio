#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <string>
#include <vector>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

Win32Window::Size GetRequestedWindowSize(
    const std::vector<std::string>& arguments) {
  constexpr int kDefaultWidth = 1280;
  constexpr int kDefaultHeight = 720;
  constexpr char kPrefix[] = "--window-size=";

  for (const auto& argument : arguments) {
    if (argument.rfind(kPrefix, 0) != 0) {
      continue;
    }
    const std::string value = argument.substr(std::string(kPrefix).length());
    const size_t separator = value.find('x');
    if (separator == std::string::npos) {
      break;
    }
    try {
      const int width = std::stoi(value.substr(0, separator));
      const int height = std::stoi(value.substr(separator + 1));
      if (width >= 320 && height >= 240) {
        return Win32Window::Size(width, height);
      }
    } catch (...) {
      break;
    }
  }
  return Win32Window::Size(kDefaultWidth, kDefaultHeight);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  Win32Window::Size size = GetRequestedWindowSize(command_line_arguments);

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  if (!window.Create(L"FH Radio Studio", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
