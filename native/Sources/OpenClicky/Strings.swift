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
    static let tutorMode = pick("Öğretici", "Tutor")
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

    // Lessons
    static let startLesson = pick("Öğretici Başlat", "Start Tutor")
    static let endLesson = pick("Dersi Bitir", "End Lesson")
    static let currentApp = pick("Şu Anki Uygulama", "Current App")

    static func currentAppNamed(_ name: String) -> String {
        isTurkish ? "Şu Anki Uygulama (\(name))" : "Current App (\(name))"
    }

    static func lessonSessionName(_ app: String) -> String {
        isTurkish ? "\(app) dersi" : "\(app) lesson"
    }

    static func lessonGreeting(_ app: String) -> String {
        isTurkish ? "\(app) dersine hazırım. ne öğrenmek istersin?" : "ready to teach \(app). what would you like to learn?"
    }

    static func lessonRunning(_ app: String) -> String {
        isTurkish ? "\(app) dersi sürüyor" : "\(app) lesson in progress"
    }

    static let lessonRunningGeneric = pick("Ders sürüyor", "Lesson in progress")
    static let tutorMenuDetail = pick("Uygulamayı seç, sor, tıkladıkça ilerlesin", "Pick an app, ask, and it follows your clicks")

    static func lookingAt(_ app: String) -> String {
        isTurkish ? "\(app)'a bakıyorum" : "Checking \(app)"
    }

    // Menu and settings window
    static let settingsMenu = pick("Ayarlar…", "Settings…")
    static let resetCursorPosition = pick("İmleci Menü Çubuğuna Döndür", "Return Cursor to Menu Bar")
    static let quitApp = pick("OpenClicky'den Çık", "Quit OpenClicky")
    static let settingsTitle = pick("OpenClicky Ayarları", "OpenClicky Settings")
    static let tabGeneral = pick("Genel", "General")
    static let tabAppearance = pick("Görünüm", "Appearance")
    static let tabConnections = pick("Bağlantılar", "Connections")
    static let tabVoice = pick("Ses", "Voice")
    static let replyLength = pick("Yanıt uzunluğu", "Reply length")
    static let replyShort = pick("Kısa", "Short")
    static let replyDetailed = pick("Ayrıntılı", "Detailed")
    static let talkShortcut = pick("Konuşma kısayolu", "Talk shortcut")
    static let color = pick("Renk", "Color")
    static let cursorSize = pick("İmleç boyutu", "Cursor size")
    static let captionSize = pick("Yazı boyutu", "Text size")
    static let sizeSmall = pick("Küçük", "Small")
    static let sizeMedium = pick("Orta", "Medium")
    static let sizeLarge = pick("Büyük", "Large")
    static let colorBlue = pick("Mavi", "Blue")
    static let colorGreen = pick("Yeşil", "Green")
    static let colorPink = pick("Pembe", "Pink")
    static let colorOrange = pick("Turuncu", "Orange")
    static let colorSlate = pick("Arduvaz", "Slate")
    static let appearanceCursor = pick("İmleç", "Cursor")
    static let appearanceCaption = pick("Sohbet kutusu", "Chat box")
    static let appearanceDrawing = pick("Çizimler", "Drawings")
    static let captionBackground = pick("Arka plan", "Background")
    static let captionText = pick("Yazı rengi", "Text color")
    static let captionFont = pick("Yazı tipi", "Font")
    static let captionOpacity = pick("Opaklık", "Opacity")
    static let captionCorners = pick("Köşe yuvarlaklığı", "Corner radius")
    static let followCursor = pick("İmleç rengiyle aynı", "Same as cursor")
    static let autoColor = pick("Otomatik", "Automatic")
    static let lineWidth = pick("Çizgi kalınlığı", "Line width")
    static let lineStyle = pick("Çizgi tipi", "Line style")
    static let lineSolid = pick("Düz", "Solid")
    static let lineDashed = pick("Kesikli", "Dashed")
    static let lineDotted = pick("Noktalı", "Dotted")
    static let drawingLook = pick("Görünüm", "Look")
    static let lookHandDrawn = pick("Elle çizilmiş", "Hand-drawn")
    static let lookClean = pick("Düzgün", "Clean")
    static let drawingEdge = pick("Beyaz kenar", "White edge")
    static let resetAppearance = pick("Varsayılana dön", "Reset to defaults")
    static let fontSystem = pick("Sistem", "System")
    static let fontRounded = pick("Yuvarlak", "Rounded")
    static let fontSerif = pick("Serif", "Serif")
    static let fontMono = pick("Sabit genişlik", "Monospaced")
    static let previewCaption = pick("Filtreler'e tıkla", "Click Filters")
    static let speakReplies = pick("Yanıtları sesli oku", "Read replies aloud")
    static let speakRepliesDetail = pick("Kapalıyken yanıt yalnızca imlecin altında görünür", "When off, replies only appear under the cursor")
    static let connectionMissing = pick("Claude Code'da tanımlı değil", "Not set up in Claude Code")
    static let connectionCanEdit = pick("Sormadan değişiklik yapabilsin", "Can make changes without asking")
    static let connectionsFooter = pick(
        "Değişiklik izni açıkken Claude sen istediğinde onay sormadan belgeni değiştirebilir; Blender'da kod çalıştırabilir, bu kod Mac'indeki dosyalara da erişebilir. Tıklama sonrası otomatik bakışlar yalnızca okur. Her bağlantı yalnızca o uygulama öndeyken ya da onun dersi sürerken açılır; bağlıyken yanıtlar gecikir ve daha çok token harcar.",
        "With changes on, Claude can change your document without asking when you request it, and can run code in Blender, which can also reach files on your Mac. Automatic looks after a click only read. Each connection opens only while its app is in front or being taught; while connected, replies take longer and use more tokens."
    )

    static func connectionTools(_ count: Int) -> String {
        isTurkish ? "\(count) araç" : "\(count) tools"
    }

    // Voice settings
    static let voiceOrder = pick("Ses sırası", "Voice order")
    static let voiceOrderFooter = pick(
        "Yanıtı listedeki ilk uygun ses okur. Çalışmazsa, örneğin ElevenLabs kredin bittiyse, sıradakine geçer.",
        "The first suitable voice reads the reply. If it fails, say your ElevenLabs credits ran out, the next one takes over."
    )
    static let voiceSystem = pick("macOS Sesi", "macOS Voice")
    static let voiceElevenLabsDetail = pick("İnternet gerekir, kredi harcar", "Needs internet, uses credits")
    static let voiceAhenkDetail = pick("Bu Mac'te çalışır, yalnızca Türkçe okur", "Runs on this Mac, reads Turkish only")
    static let voiceSystemDetail = pick("Bu Mac'te çalışır, her dili okur", "Runs on this Mac, reads any language")
    static let voiceNeedsKey = pick("API anahtarı gerekli", "API key needed")
    static let voiceNotInstalled = pick("Kurulu değil", "Not installed")
    static let voiceMoveUp = pick("Yukarı taşı", "Move up")
    static let voiceMoveDown = pick("Aşağı taşı", "Move down")
    static let voiceTry = pick("Sesi dene", "Try voice")
    static let voiceSample = pick("Merhaba, yanıtlarını bu sesle okuyacağım.", "Hi, I'll read your replies in this voice.")
    static let voiceSampleTurkish = "Merhaba, yanıtlarını bu sesle okuyacağım."
    static let noVoiceForText = pick("Açık seslerden hiçbiri bu yanıtı okuyamadı.", "None of the voices that are on could read this reply.")

    static func voiceLastUsed(_ name: String) -> String {
        isTurkish ? "Son yanıtı okuyan: \(name)" : "Last reply read by: \(name)"
    }

    static let voiceSettings = pick("ElevenLabs", "ElevenLabs")
    static let voiceBody = pick(
        "Anahtar Bu Mac'in Anahtar Zinciri'nde saklanır.",
        "The key is kept in this Mac's Keychain."
    )
    static let apiKey = pick("API anahtarı", "API key")
    static let voiceId = pick("Ses kimliği (isteğe bağlı)", "Voice ID (optional)")
    static let save = pick("Kaydet", "Save")
    static let clear = pick("Temizle", "Clear")
    static let saved = pick("Kaydedildi", "Saved")
    static let cleared = pick("Temizlendi", "Cleared")
    static let back = pick("Geri", "Back")
}
