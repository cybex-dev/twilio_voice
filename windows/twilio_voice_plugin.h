#ifndef FLUTTER_PLUGIN_TWILIO_VOICE_PLUGIN_H_
#define FLUTTER_PLUGIN_TWILIO_VOICE_PLUGIN_H_

#include <windows.h>
#include <windows.ui.notifications.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>
#include <windows.data.xml.dom.h>
#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/plugin_registrar_windows.h>
#include "webview/tv_webview.h"
#include <memory>
#include <map>
#include <notificationactivationcallback.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <propvarutil.h>

namespace twilio_voice {

// Define the GUID for the notification activation callback
// {A9B4F96E-0E54-4B7A-B8B2-2BF72E1E83B4}
DEFINE_GUID(CLSID_TVNotificationActivationCallback,
    0xa9b4f96e, 0xe54, 0x4b7a, 0xb8, 0xb2, 0x2b, 0xf7, 0x2e, 0x1e, 0x83, 0xb4);

class TVNotificationManager {
public:
    static TVNotificationManager& getInstance();
    void showIncomingCallNotification(const std::string& from, const std::string& callSid);
    void showMissedCallNotification(const std::string& from, const std::string& callSid);
    void hideNotification(const std::string& callSid, bool isIncomingCall);
    void hideAllNotifications();
    static void setWebView(TVWebView* webview) { webview_ = webview; }
    bool hasNotificationPermission();
    bool requestNotificationPermission();
    static bool RegisterCOMServer();
    static void UnregisterCOMServer();
    std::wstring getLastNotificationArgs() const;

protected:
    struct NotificationInfo {
        Microsoft::WRL::ComPtr<ABI::Windows::UI::Notifications::IToastNotification> notification;
        bool isIncomingCall;
    };
    std::map<std::string, NotificationInfo> activeNotifications;
    Microsoft::WRL::ComPtr<ABI::Windows::UI::Notifications::IToastNotifier> toastNotifier;
    Microsoft::WRL::ComPtr<ABI::Windows::UI::Notifications::IToastNotificationManagerStatics> toastManager;
    std::wstring lastNotificationArgs_;
    static TVWebView* webview_;
    static DWORD comRegistrationCookie;

private:
    TVNotificationManager();
    ~TVNotificationManager() = default;

    void ShowNotificationInternal(const std::string& from, const std::string& callSid, bool isIncomingCall);
    bool InitializeNotificationSystem();

    friend class TVNotificationActivationCallback;
};

class TVNotificationActivationCallback : public Microsoft::WRL::RuntimeClass<
    Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
    INotificationActivationCallback> {
public:
    TVNotificationActivationCallback() = default;
    ~TVNotificationActivationCallback() = default;

    // INotificationActivationCallback
    IFACEMETHODIMP Activate(
        LPCWSTR appUserModelId,
        LPCWSTR invokedArgs,
        const NOTIFICATION_USER_INPUT_DATA* data,
        ULONG count) override;

private:
    HRESULT HandleNotificationAction(const std::wstring& action);
};

class TwilioVoicePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  TwilioVoicePlugin(flutter::PluginRegistrarWindows* registrar);
  virtual ~TwilioVoicePlugin();

  // Static methods for call handling
  static void AnswerCall(TVWebView* webview, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  static void HangUpCall(TVWebView* webview, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  static void MakeCall(TVWebView *webview, const std::string &from, const std::string &to, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  static void FlashWindowTaskbar(HWND hwnd, bool flash);

 private:
  std::unique_ptr<TVWebView> webview_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::StreamHandler<flutter::EncodableValue>> stream_handler_;
  flutter::PluginRegistrarWindows* registrar_;
  flutter::EventSink<flutter::EncodableValue>* event_sink_ = nullptr;
  
  void InitializeWebView();
  void SendEventToFlutter(const std::string &event);

  // Mic permission handling
   bool TwilioVoicePlugin::CheckWindowsMicrophonePermission();
  void CheckMicrophonePermission(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result = nullptr);

  // Disallow copy and assign.
  TwilioVoicePlugin(const TwilioVoicePlugin&) = delete;
  TwilioVoicePlugin& operator=(const TwilioVoicePlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  static void UnsubscribeDeviceEventHandlers(TVWebView *webview);
  static void UnsubscribeConnectionEventHandlers(TVWebView *webview);
};

}  // namespace twilio_voice

#endif  // FLUTTER_PLUGIN_TWILIO_VOICE_PLUGIN_H_
