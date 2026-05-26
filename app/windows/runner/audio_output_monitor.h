#ifndef RUNNER_AUDIO_OUTPUT_MONITOR_H_
#define RUNNER_AUDIO_OUTPUT_MONITOR_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <windows.h>

#include <memory>

constexpr UINT kAudioOutputChangedMessage = WM_APP + 0x468;

class AudioOutputMonitor : public IMMNotificationClient {
 public:
  AudioOutputMonitor(flutter::BinaryMessenger* messenger, HWND window);
  ~AudioOutputMonitor();

  AudioOutputMonitor(const AudioOutputMonitor&) = delete;
  AudioOutputMonitor& operator=(const AudioOutputMonitor&) = delete;

  bool Start();
  void Stop();
  void EmitDefaultOutputChanged();

  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override;
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(
      EDataFlow flow,
      ERole role,
      LPCWSTR default_device_id) override;
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR device_id) override;
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR device_id) override;
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR device_id,
                                                 DWORD new_state) override;
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(
      LPCWSTR device_id,
      const PROPERTYKEY key) override;

 private:
  HWND window_;
  IMMDeviceEnumerator* enumerator_ = nullptr;
  bool registered_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_AUDIO_OUTPUT_MONITOR_H_
