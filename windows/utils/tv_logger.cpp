#include "tv_logger.h"
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <sstream>

namespace twilio_voice {

TVLogger& TVLogger::getInstance() {
    static TVLogger instance;
    return instance;
}

void TVLogger::setMethodChannel(flutter::MethodChannel<flutter::EncodableValue>* channel) {
    methodChannel_ = channel;
}

void TVLogger::debug(const std::string& message) {
    log("DEBUG", message);
}

void TVLogger::error(const std::string& message) {
    log("ERROR", message);
}

void TVLogger::info(const std::string& message) {
    log("INFO", message);
}

void TVLogger::log(const std::string& level, const std::string& message) {
    // Convert to wide string for Windows debug output
    std::wstring wlevel(level.begin(), level.end());
    std::wstring wmessage(message.begin(), message.end());
    
    std::wostringstream wlogMsg;
    wlogMsg << L"Twilio Voice [" << wlevel << L"]: " << wmessage << L"\n";
    OutputDebugStringW(wlogMsg.str().c_str());

    // Also output to console
    std::cout << "Twilio Voice [" << level << "]: " << message << std::endl;

    if (!methodChannel_) {
        return;
    }

    flutter::EncodableMap map;
    map[flutter::EncodableValue("type")] = flutter::EncodableValue("LOG");
    map[flutter::EncodableValue("level")] = flutter::EncodableValue(level);
    map[flutter::EncodableValue("message")] = flutter::EncodableValue(message);
    
    methodChannel_->InvokeMethod("onCallEvent",
        std::make_unique<flutter::EncodableValue>(map));
}

} // namespace twilio_voice
