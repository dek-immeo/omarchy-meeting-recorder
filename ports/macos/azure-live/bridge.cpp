// C boundary to the official Microsoft Speech SDK. One continuous recognizer per audio source.
#include <speechapi_cxx.h>
#include <memory>

using namespace Microsoft::CognitiveServices::Speech;
using Event = void (*)(unsigned kind, unsigned source, uint64_t ms, const char* text);

struct Channel {
    std::shared_ptr<Audio::PushAudioInputStream> stream;
    std::shared_ptr<SpeechRecognizer> recognizer;
};

extern "C" void* meeting_speech_open(const char* url, const char* key, const char* language,
                                    unsigned source, uint64_t start_ms, Event emit) noexcept {
    try {
        auto config = SpeechConfig::FromEndpoint(url, key);
        config->SetSpeechRecognitionLanguage(language);
        auto channel = std::make_unique<Channel>();
        channel->stream = Audio::AudioInputStream::CreatePushStream(); // 16 kHz mono signed PCM16
        auto recognizer = SpeechRecognizer::FromConfig(config, Audio::AudioConfig::FromStreamInput(channel->stream));
        channel->recognizer = recognizer;
        auto caption = [=](unsigned kind, const SpeechRecognitionEventArgs& event) {
            emit(kind, source, start_ms + event.Result->Offset() / 10000, event.Result->Text.c_str());
        };
        recognizer->Recognizing.Connect([caption](const SpeechRecognitionEventArgs& e) { caption(0, e); });
        recognizer->Recognized.Connect([caption](const SpeechRecognitionEventArgs& e) { caption(1, e); });
        recognizer->Canceled.Connect([=](const SpeechRecognitionCanceledEventArgs& e) {
            if (e.Reason == CancellationReason::Error) {
                // SDK diagnostics may contain connection details. Report only the structured code.
                auto code = std::to_string(static_cast<int>(e.ErrorCode));
                emit(2, source, 0, code.c_str());
            }
        });
        recognizer->SessionStopped.Connect([=](const SessionEventArgs&) {
            emit(2, source, 0, "session afsluttet");
        });
        recognizer->StartContinuousRecognitionAsync().get();
        return channel.release();
    } catch (...) { return nullptr; }
}

extern "C" bool meeting_speech_write(void* raw, const uint8_t* pcm, uint32_t bytes) noexcept {
    try {
        static_cast<Channel*>(raw)->stream->Write(const_cast<uint8_t*>(pcm), bytes);
        return true;
    } catch (...) { return false; }
}

