#pragma once
#include <WebView2.h>
#include <wrl.h>
#include <functional>
#include <string>

class TVWebView {
public:
    TVWebView(HWND parentWindow);
    ~TVWebView();

    void initialize(std::function<void()> completionHandler);
    void evaluateJavaScript(const std::wstring& javascript, 
                          std::function<void(void*, std::string)> completionHandler);
    void loadHtmlString(const std::wstring& html);
    void loadFile(const std::wstring& filePath, std::function<void()> completionHandler = nullptr);
    void cleanup();
    
    ICoreWebView2* getWebView() { return webview_.Get(); }

private:
    Microsoft::WRL::ComPtr<ICoreWebView2> webview_;
    Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller_;
    Microsoft::WRL::ComPtr<ICoreWebView2Settings> settings_;
    bool loggingEnabled_ = false;
    HWND parentWindow_;
    EventRegistrationToken navigationCompletedToken_;
    EventRegistrationToken permissionRequestedToken_;
};
