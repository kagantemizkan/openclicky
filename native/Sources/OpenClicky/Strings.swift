//
//  Strings.swift
//  Interface text in the user's first system language, Turkish or English.
//  Read from preferred languages rather than Locale.current, which can be
//  en_TR on a Turkish user's Mac.
//

import Foundation

enum Strings {
    static let locale = Locale(identifier: Locale.preferredLanguages.first ?? "en")
    private static let isTurkish = locale.language.languageCode?.identifier == "tr"

    private static func pick(_ turkish: String, _ english: String) -> String {
        isTurkish ? turkish : english
    }

    // Cursor
    static let listening = pick("Dinliyorum", "Listening")
    static let thinking = pick("Düşünüyorum", "Thinking")

    // Status
    static let ready = pick("Konuşmak için Control + Option'a basılı tut", "Hold Control + Option to talk")
    static let listeningStatus = pick("Dinliyorum…", "Listening…")
    static let thinkingStatus = pick("Düşünüyorum…", "Thinking…")
    static let speakingStatus = pick("Konuşuyorum…", "Speaking…")

    // Sessions
    static let session = pick("Oturum", "Session")
    static let newSessionName = pick("Yeni oturum", "New session")
    static let newSession = pick("Yeni Oturum", "New Session")
    static let renameSession = pick("Yeniden Adlandır…", "Rename…")
    static let deleteSession = pick("Oturumu Sil…", "Delete Session…")
    static let sessionNamePlaceholder = pick("Oturum adı", "Session name")
    static let deleteQuestion = pick("Bu oturum listeden silinsin mi?", "Remove this session from the list?")
    static let cancel = pick("Vazgeç", "Cancel")
    static let delete = pick("Sil", "Delete")
    static let noTokensYet = pick("Henüz token kullanılmadı", "No tokens used yet")
    static let sessionGone = pick(
        "Bu konuşma Claude'da artık yok. Bir sonraki soru yeni bir konuşma başlatır.",
        "Claude no longer has this conversation. The next question starts a new one."
    )

    static func usageLine(tokens: String, turns: Int) -> String {
        isTurkish ? "\(tokens) token · \(turns) tur" : "\(tokens) tokens · \(turns) \(turns == 1 ? "turn" : "turns")"
    }

    static func usageDetail(input: String, cacheWrite: String, cacheRead: String, output: String, context: String) -> String {
        isTurkish
            ? "Girdi \(input), önbelleğe yazılan \(cacheWrite), yanıt \(output). Önbellekten okunan \(cacheRead) toplama dahil değil. Son turdaki konuşma boyutu \(context)."
            : "Input \(input), cache writes \(cacheWrite), output \(output). Cache reads of \(cacheRead) aren't included in the total. Last turn's conversation size \(context)."
    }

    static func compact(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).locale(locale))
    }

    // Asking
    static let askPlaceholder = pick("Yazarak sor", "Type a question")
    static let send = pick("Gönder", "Send")
    static let stop = pick("Durdur (Esc)", "Stop (Esc)")

    // Options
    static let tutorMode = pick("Öğretici mod", "Tutor mode")
    static let tutorModeDetail = pick("Her tıklamadan sonra ekrana yeniden bakar", "Looks again after each click")
    static let cursorAtRest = pick("İmleci boştayken göster", "Show cursor at rest")
    static let cursorAtRestDetail = pick("Menü çubuğundaki simgenin altında bekler", "Waits below the menu bar icon")
    static let model = pick("Model", "Model")
    static let settings = pick("Ayarlar", "Settings")
    static let quit = pick("Çıkış", "Quit")

    static func tutorLimitReached(_ count: Int) -> String {
        isTurkish
            ? "Öğretici mod \(count) otomatik bakıştan sonra durdu. Devam etmek için konuş."
            : "Tutor mode stopped after \(count) automatic looks. Speak to continue."
    }

    // Permissions
    static let openSettings = pick("Ayarları Aç", "Open Settings")
    static let askMacOS = pick("İzin İste", "Request Access")
    static let retry = pick("Tekrar Dene", "Try Again")
    static let installTitle = pick("Claude Code gerekli", "Claude Code required")
    static let installBody = pick(
        "OpenClicky, Claude Code oturumunu kullanır; ayrı bir anahtar gerekmez. Kurup bir kez giriş yapman yeterli.",
        "OpenClicky uses your Claude Code login, so no extra keys are needed. Install it and sign in once."
    )
    static let installButton = pick("Kurulum Sayfasını Aç", "Open Install Page")
    static let screenTitle = pick("Ekran Kaydı izni gerekli", "Screen Recording required")
    static let screenBody = pick(
        "Ekranını yalnızca sen sorduğunda ya da öğretici mod açıkken yakalar. İzni verince bu uyarı kendiliğinden kalkar.",
        "Your screen is captured only when you ask or while tutor mode is on. This goes away once access is granted."
    )
    static let relaunchTitle = pick("Yeniden başlatman gerekiyor", "Relaunch required")
    static let relaunchBody = pick(
        "İzin verildi, ama macOS bunu yalnızca sonradan açılan uygulamalara uygular. Çıkıp OpenClicky'yi yeniden aç.",
        "Access is granted, but macOS applies it only to apps opened afterwards. Quit and reopen OpenClicky."
    )
    static let accessibilityTitle = pick("Erişilebilirlik izni gerekli", "Accessibility required")
    static let accessibilityBody = pick(
        "Control + Option tuşlarını algılamak için gerekli. Yazdıklarını okumaz. İzni verince bu uyarı kendiliğinden kalkar.",
        "Needed to detect Control + Option. It doesn't read what you type. This goes away once access is granted."
    )
    static let micTitle = pick("Mikrofon izni gerekli", "Microphone required")
    static let micBody = pick(
        "Sistem Ayarları'nda Gizlilik ve Güvenlik > Mikrofon bölümünden OpenClicky'yi aç.",
        "Turn on OpenClicky in System Settings > Privacy & Security > Microphone."
    )
    static let speechTitle = pick("Konuşma Tanıma izni gerekli", "Speech Recognition required")
    static let speechBody = pick(
        "Sistem Ayarları'nda Gizlilik ve Güvenlik > Konuşma Tanıma bölümünden OpenClicky'yi aç.",
        "Turn on OpenClicky in System Settings > Privacy & Security > Speech Recognition."
    )

    // Voice settings
    static let voiceSettings = pick("ElevenLabs Sesi", "ElevenLabs Voice")
    static let voiceBody = pick(
        "İstersen yanıtları ElevenLabs sesiyle okutabilirsin. Boş bırakırsan yerel ses kullanılır.",
        "Optionally read replies in an ElevenLabs voice. Leave this blank to use the local voice."
    )
    static let apiKey = pick("API anahtarı", "API key")
    static let voiceId = pick("Ses kimliği (isteğe bağlı)", "Voice ID (optional)")
    static let save = pick("Kaydet", "Save")
    static let clear = pick("Temizle", "Clear")
    static let saved = pick("Kaydedildi", "Saved")
    static let cleared = pick("Temizlendi", "Cleared")
    static let back = pick("Geri", "Back")
}
