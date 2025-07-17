#pragma once
#include <string>

// Forward declare Flutter types
namespace flutter {
    template<typename T> class MethodChannel;
    class EncodableValue;
}

namespace twilio_voice {

class TVLogger {
public:
    static TVLogger& getInstance();
    
    void debug(const std::string& message);
    void error(const std::string& message);
    void info(const std::string& message);
    
    void setMethodChannel(flutter::MethodChannel<flutter::EncodableValue>* channel);

private:
    TVLogger() = default;
    void log(const std::string& level, const std::string& message);
    
    flutter::MethodChannel<flutter::EncodableValue>* methodChannel_ = nullptr;
};

// Convenience macros
#define TV_LOG_DEBUG(msg) twilio_voice::TVLogger::getInstance().debug(msg)
#define TV_LOG_ERROR(msg) twilio_voice::TVLogger::getInstance().error(msg)
#define TV_LOG_INFO(msg) twilio_voice::TVLogger::getInstance().info(msg)

} // namespace twilio_voice
