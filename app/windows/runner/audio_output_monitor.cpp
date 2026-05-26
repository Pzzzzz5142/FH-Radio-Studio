#include "audio_output_monitor.h"

#include <flutter/encodable_value.h>

AudioOutputMonitor::AudioOutputMonitor(flutter::BinaryMessenger* messenger,
                                       HWND window)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "fh_radio_studio/audio_output",
          &flutter::StandardMethodCodec::GetInstance())) {}

AudioOutputMonitor::~AudioOutputMonitor() {
  Stop();
}

bool AudioOutputMonitor::Start() {
  if (registered_) {
    return true;
  }
  if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator_)))) {
    enumerator_ = nullptr;
    return false;
  }
  if (FAILED(enumerator_->RegisterEndpointNotificationCallback(this))) {
    enumerator_->Release();
    enumerator_ = nullptr;
    return false;
  }
  registered_ = true;
  return true;
}

void AudioOutputMonitor::Stop() {
  if (enumerator_ != nullptr) {
    if (registered_) {
      enumerator_->UnregisterEndpointNotificationCallback(this);
      registered_ = false;
    }
    enumerator_->Release();
    enumerator_ = nullptr;
  }
}

void AudioOutputMonitor::EmitDefaultOutputChanged() {
  flutter::EncodableMap event;
  event[flutter::EncodableValue("platform")] =
      flutter::EncodableValue("windows");
  channel_->InvokeMethod(
      "defaultOutputChanged",
      std::make_unique<flutter::EncodableValue>(std::move(event)));
}

ULONG AudioOutputMonitor::AddRef() {
  return 1;
}

ULONG AudioOutputMonitor::Release() {
  return 1;
}

HRESULT AudioOutputMonitor::QueryInterface(REFIID riid, void** object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  if (riid == __uuidof(IUnknown) ||
      riid == __uuidof(IMMNotificationClient)) {
    *object = static_cast<IMMNotificationClient*>(this);
    AddRef();
    return S_OK;
  }
  *object = nullptr;
  return E_NOINTERFACE;
}

HRESULT AudioOutputMonitor::OnDefaultDeviceChanged(
    EDataFlow flow,
    ERole role,
    LPCWSTR default_device_id) {
  if (flow == eRender) {
    ::PostMessage(window_, kAudioOutputChangedMessage, 0, 0);
  }
  return S_OK;
}

HRESULT AudioOutputMonitor::OnDeviceAdded(LPCWSTR device_id) {
  return S_OK;
}

HRESULT AudioOutputMonitor::OnDeviceRemoved(LPCWSTR device_id) {
  return S_OK;
}

HRESULT AudioOutputMonitor::OnDeviceStateChanged(LPCWSTR device_id,
                                                 DWORD new_state) {
  return S_OK;
}

HRESULT AudioOutputMonitor::OnPropertyValueChanged(LPCWSTR device_id,
                                                   const PROPERTYKEY key) {
  return S_OK;
}
