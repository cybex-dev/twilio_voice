#include "include/twilio_voice/twilio_voice_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "twilio_voice_plugin.h"

void TwilioVoicePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  twilio_voice::TwilioVoicePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
