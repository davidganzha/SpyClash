import CryptoKit
import Foundation

enum AppLanguage: String, CaseIterable, Codable, Hashable, Identifiable {
    case en
    case es
    case ru

    static let storageKey = "spy_lang"

    var id: String { rawValue }

    var shortCode: String { rawValue.uppercased() }

    var title: String {
        switch self {
        case .en: "English"
        case .es: "Español"
        case .ru: "Русский"
        }
    }

    var profileLanguageLabel: String {
        switch self {
        case .en: "LANGUAGE"
        case .es: "IDIOMA"
        case .ru: "LANGUAGE / ЯЗЫК"
        }
    }

    var languageSavedMessage: String {
        switch self {
        case .en: "LANGUAGE SAVED"
        case .es: "IDIOMA GUARDADO"
        case .ru: "ЯЗЫК СОХРАНЕН"
        }
    }

    var languageFailedMessage: String {
        switch self {
        case .en: "LANGUAGE SYNC FAILED"
        case .es: "ERROR AL SINCRONIZAR IDIOMA"
        case .ru: "СИНХРОНИЗАЦИЯ ЯЗЫКА НЕ УДАЛАСЬ"
        }
    }

    var profileLegalHint: String {
        switch self {
        case .en:
            "Review the same field rules and privacy policy from the web command center."
        case .es:
            "Revisa las mismas reglas y politica de privacidad del centro web."
        case .ru:
            "Открой те же правила и политику приватности, что и в веб-версии."
        }
    }

    var howToPlayTitle: String {
        switch self {
        case .en: "HOW TO PLAY?"
        case .es: "¿CÓMO JUGAR?"
        case .ru: "КАК ИГРАТЬ?"
        }
    }

    var tutorialHeader: String {
        switch self {
        case .en: "// TUTORIAL"
        case .es: "// TUTORIAL"
        case .ru: "// ТУТОРИАЛ"
        }
    }

    var bootSyncingFieldKit: String {
        switch self {
        case .en: "SYNCING FIELD KIT"
        case .es: "SINCRONIZANDO EQUIPO"
        case .ru: "СИНХРОНИЗАЦИЯ НАБОРА"
        }
    }

    var tutorialNext: String {
        switch self {
        case .en: "NEXT"
        case .es: "SIGUIENTE"
        case .ru: "ДАЛЬШЕ"
        }
    }

    var tutorialBack: String {
        switch self {
        case .en: "BACK"
        case .es: "ATRÁS"
        case .ru: "НАЗАД"
        }
    }

    var tutorialDone: String {
        switch self {
        case .en: "GOT IT"
        case .es: "ENTENDIDO"
        case .ru: "ПОНЯТНО"
        }
    }

    func tutorialModeTitle(_ mode: TutorialMode) -> String {
        switch (self, mode) {
        case (.en, .questions): "QUESTIONS"
        case (.en, .associations): "ASSOCIATIONS"
        case (.es, .questions): "PREGUNTAS"
        case (.es, .associations): "ASOCIACIONES"
        case (.ru, .questions): "ВОПРОСЫ"
        case (.ru, .associations): "АССОЦИАЦИИ"
        }
    }

    func tutorialSteps(for mode: TutorialMode) -> [TutorialStep] {
        switch (self, mode) {
        case (.ru, .questions):
            [
                TutorialStep(icon: "🎭", title: "Роли", text: "В начале игры каждый тайно читает свою карточку роли. Детективы видят секретное слово и категорию. Шпион ничего не видит — только список слов, из которых нужно будет угадать."),
                TutorialStep(icon: "❓", title: "Вопросы и ответы", text: "Игроки ходят по кругу: один задаёт вопрос, другой отвечает вслух. Когда спрашивающий услышал ответ — он нажимает «Ответ услышан» и ход переходит дальше. Вопросы должны намекать на слово, но не раскрывать его шпиону."),
                TutorialStep(icon: "🗳️", title: "Голосование за шпиона", text: "Любой игрок может запросить голосование. Когда достаточно игроков соглашаются — все голосуют за того, кого считают шпионом. Большинство угадало шпиона — детективы победили!"),
                TutorialStep(icon: "🎯", title: "Угадывание шпиона", text: "Шпион может в любой момент нажать «Угадать досрочно» и выбрать слово из списка. Угадал — шпион побеждает! Ошибся — детективы побеждают немедленно.")
            ]
        case (.ru, .associations):
            [
                TutorialStep(icon: "🎭", title: "Роли", text: "В начале каждый тайно читает свою карточку роли. Детективы видят секретное слово. Шпион ничего не видит — вместо слова у него «???»."),
                TutorialStep(icon: "🎰", title: "Барабан", text: "Хост запускает барабан — он случайно выбирает игрока. Этот игрок должен назвать вслух ОДНО слово-ассоциацию к секретному слову, затем нажать «Ответил»."),
                TutorialStep(icon: "🔄", title: "Без повторов", text: "Каждый игрок говорит по одному разу за раунд. Когда все высказались — начинается следующий раунд с новым случайным порядком."),
                TutorialStep(icon: "🎯", title: "Найди шпиона", text: "Услышав ассоциации, проголосуйте за того, кто, по-вашему, шпион. Шпион может угадать секретное слово в любой момент и победить!")
            ]
        case (.es, .questions):
            [
                TutorialStep(icon: "🎭", title: "Roles", text: "Al comenzar, cada persona lee su carta de rol en secreto. Los detectives ven la palabra secreta y la categoría. El espía solo ve la lista de palabras entre las que tendrá que adivinar."),
                TutorialStep(icon: "❓", title: "Preguntas y respuestas", text: "Los jugadores avanzan en círculo: una persona pregunta y otra responde en voz alta. Al oír la respuesta, pulsa «Respuesta recibida» para continuar. Da pistas sin revelar la palabra al espía."),
                TutorialStep(icon: "🗳️", title: "Votar al espía", text: "Cualquier jugador puede solicitar una votación. Cuando suficientes jugadores aceptan, todos señalan a quien creen que es el espía. Si la mayoría acierta, ganan los detectives."),
                TutorialStep(icon: "🎯", title: "Adivinar la palabra", text: "El espía puede intentar adivinar la palabra en cualquier momento. Si acierta, gana. Si falla, los detectives ganan de inmediato.")
            ]
        case (.es, .associations):
            [
                TutorialStep(icon: "🎭", title: "Roles", text: "Al comenzar, cada persona lee su carta de rol en secreto. Los detectives ven la palabra secreta. El espía solo ve «???»."),
                TutorialStep(icon: "🎰", title: "La ruleta", text: "El anfitrión activa la ruleta para elegir un jugador. Esa persona dice en voz alta UNA asociación con la palabra secreta y después pulsa «Respondido»."),
                TutorialStep(icon: "🔄", title: "Sin repetir", text: "Cada jugador habla una vez por ronda. Cuando todos han participado, comienza otra ronda con un orden aleatorio nuevo."),
                TutorialStep(icon: "🎯", title: "Encuentra al espía", text: "Escucha las asociaciones y vota por quien creas que es el espía. El espía puede adivinar la palabra secreta en cualquier momento para ganar.")
            ]
        case (.en, .questions):
            [
                TutorialStep(icon: "🎭", title: "Roles", text: "At game start everyone secretly reads their role card. Detectives see the secret word and category. The Spy sees nothing — only the word list to guess from later."),
                TutorialStep(icon: "❓", title: "Q&A", text: "Players go in a circle: one asks a question, another answers out loud. When the asker has heard the answer, they press 'Answer Received' to move on. Questions should hint at the word without revealing it to the spy."),
                TutorialStep(icon: "🗳️", title: "Voting for the Spy", text: "Any player can request a vote. Once enough players agree, everyone votes for who they think is the spy. If the majority picks the spy — detectives win!"),
                TutorialStep(icon: "🎯", title: "Spy's Guess", text: "The spy can press 'Guess Word Early' at any time and pick from the word list. Guess correctly — spy wins! Wrong guess — detectives win immediately.")
            ]
        case (.en, .associations):
            [
                TutorialStep(icon: "🎭", title: "Roles", text: "At game start everyone secretly reads their role card. Detectives see the secret word. The Spy sees nothing — only '???' instead of the word."),
                TutorialStep(icon: "🎰", title: "The Drum", text: "The host spins the drum — it randomly picks a player. That player must say ONE word associated with the secret word out loud, then press 'Answered'."),
                TutorialStep(icon: "🔄", title: "No Repeats", text: "Each player speaks once per round. When everyone has given an association — a new round begins automatically with a fresh random order."),
                TutorialStep(icon: "🎯", title: "Find the Spy", text: "After hearing associations, vote for who you think is the spy. The spy can guess the secret word at any time to win!")
            ]
        }
    }

    var welcome: WelcomeCopy {
        switch self {
        case .en:
            WelcomeCopy(
                statusPrefix: "STATUS:",
                locked: "LOCKED",
                tagline: "DECEPTION · DEDUCTION · DOMINATION",
                enterGame: "ENTER THE GAME",
                createAccount: "CREATE ACCOUNT",
                privacy: "PRIVACY",
                terms: "TERMS",
                invitePrefix: "INVITE",
                inviteSuffix: "ARMED"
            )
        case .es:
            WelcomeCopy(
                statusPrefix: "ESTADO:",
                locked: "BLOQUEADO",
                tagline: "ENGAÑO · DEDUCCIÓN · DOMINIO",
                enterGame: "ENTRAR AL JUEGO",
                createAccount: "CREAR CUENTA",
                privacy: "PRIVACIDAD",
                terms: "TÉRMINOS",
                invitePrefix: "INVITACIÓN",
                inviteSuffix: "ACTIVA"
            )
        case .ru:
            WelcomeCopy(
                statusPrefix: "СТАТУС:",
                locked: "ЗАКРЫТО",
                tagline: "ОБМАН · ДЕДУКЦИЯ · ДОМИНАЦИЯ",
                enterGame: "ВОЙТИ В ИГРУ",
                createAccount: "СОЗДАТЬ АККАУНТ",
                privacy: "ПРИВАТНОСТЬ",
                terms: "ПРАВИЛА",
                invitePrefix: "ПРИГЛАШЕНИЕ",
                inviteSuffix: "АКТИВЕН"
            )
        }
    }

    var auth: AuthCopy {
        switch self {
        case .en:
            AuthCopy(
                accessTerminal: "ACCESS TERMINAL",
                passphraseRequired: "PASSPHRASE REQUIRED",
                newOperative: "NEW OPERATIVE",
                setPassphrase: "SET PASSPHRASE",
                verificationRequired: "VERIFICATION REQUIRED",
                recoveryProtocol: "RECOVERY PROTOCOL",
                transmissionSent: "TRANSMISSION SENT",
                setNewPassphrase: "SET NEW PASSPHRASE",
                welcomeBack: "Welcome Back",
                joinNetworkTitle: "Join the Network",
                createPassphraseTitle: "Create Passphrase",
                confirmIdentityTitle: "Confirm Identity",
                resetPassphraseTitle: "Reset Passphrase",
                checkInboxTitle: "Check Inbox",
                newCredentialsTitle: "New Credentials",
                emailSubtitle: "Authenticate to continue the mission",
                passwordSubtitle: "One final step",
                registerEmailSubtitle: "Create credentials to enter the game",
                registerPasswordSubtitle: "Choose a secure key",
                otpSubtitlePrefix: "Transmission sent to",
                forgotPasswordEmptySubtitle: "Request a secure reset link",
                forgotPasswordPrefix: "Recovery link for",
                resetEmailSentPrefix: "Recovery link sent to",
                resetPasswordSubtitle: "Choose a strong new passphrase",
                continueAction: "CONTINUE",
                unlockAction: "UNLOCK",
                joinNetworkAction: "JOIN THE NETWORK",
                createCredentialsAction: "CREATE CREDENTIALS",
                verifyEnterAction: "VERIFY & ENTER",
                dispatchResetLinkAction: "DISPATCH RESET LINK",
                confirmNewKeyAction: "CONFIRM NEW KEY",
                authenticatingBusy: "AUTHENTICATING...",
                recruitingBusy: "RECRUITING...",
                verifyingBusy: "VERIFYING...",
                dispatchingBusy: "DISPATCHING...",
                resettingBusy: "RESETTING...",
                passphraseLabel: "// PASSPHRASE",
                confirmPassphraseLabel: "// CONFIRM PASSPHRASE",
                newPassphraseLabel: "// NEW PASSPHRASE",
                sixDigitKeyLabel: "// 6-DIGIT KEY",
                forgotPassphrase: "FORGOT PASSPHRASE?",
                requestResetBody: "Request a secure reset link for your operative email.",
                resetInboxTitle: "CHECK YOUR INBOX",
                resetInboxDetailPrefix: "If credentials exist for",
                resetInboxDetailSuffix: "a recovery link is en route.",
                backToLogin: "BACK TO LOGIN",
                continueWithApple: "Continue with Apple",
                appleSheetTitle: "Sign in with Apple",
                appleSheetBody: "Use your Apple ID to enter SpyClash. Your Apple password is handled only by Apple.",
                appleSheetDismiss: "NOT NOW",
                continueWithGoogle: "CONTINUE WITH GOOGLE",
                emailDivider: "OR WITH EMAIL",
                requestAccessFooter: "REQUEST ACCESS",
                loginFooter: "LOG IN",
                passphrasesMismatch: "Passphrases do not match.",
                recoveryLinkNotice: "If credentials exist for that email, a recovery link is en route.",
                passphraseUpdatedNotice: "Passphrase updated. Log in with your new key.",
                appleMissingToken: "Apple callback did not include an access token.",
                googleMissingToken: "Google callback did not include an access token.",
                chooseNewPassphraseNotice: "Choose a new passphrase to restore access.",
                signInToJoinPrefix: "SIGN IN TO JOIN",
                emailPlaceholder: "operative@example.com"
            )
        case .es:
            AuthCopy(
                accessTerminal: "TERMINAL DE ACCESO",
                passphraseRequired: "CLAVE REQUERIDA",
                newOperative: "NUEVO OPERATIVO",
                setPassphrase: "CREAR CLAVE",
                verificationRequired: "VERIFICACIÓN REQUERIDA",
                recoveryProtocol: "PROTOCOLO DE RECUPERACIÓN",
                transmissionSent: "TRANSMISIÓN ENVIADA",
                setNewPassphrase: "NUEVA CLAVE",
                welcomeBack: "Bienvenido de nuevo",
                joinNetworkTitle: "Únete a la red",
                createPassphraseTitle: "Crea una clave",
                confirmIdentityTitle: "Confirma tu identidad",
                resetPassphraseTitle: "Restablece tu clave",
                checkInboxTitle: "Revisa tu correo",
                newCredentialsTitle: "Nuevas credenciales",
                emailSubtitle: "Autentícate para continuar la misión",
                passwordSubtitle: "Un último paso",
                registerEmailSubtitle: "Crea tus credenciales para entrar al juego",
                registerPasswordSubtitle: "Elige una clave segura",
                otpSubtitlePrefix: "Transmisión enviada a",
                forgotPasswordEmptySubtitle: "Solicita un enlace seguro de recuperación",
                forgotPasswordPrefix: "Enlace de recuperación para",
                resetEmailSentPrefix: "Enlace de recuperación enviado a",
                resetPasswordSubtitle: "Elige una nueva clave segura",
                continueAction: "CONTINUAR",
                unlockAction: "DESBLOQUEAR",
                joinNetworkAction: "UNIRSE A LA RED",
                createCredentialsAction: "CREAR CREDENCIALES",
                verifyEnterAction: "VERIFICAR Y ENTRAR",
                dispatchResetLinkAction: "ENVIAR ENLACE",
                confirmNewKeyAction: "CONFIRMAR NUEVA CLAVE",
                authenticatingBusy: "AUTENTICANDO...",
                recruitingBusy: "REGISTRANDO...",
                verifyingBusy: "VERIFICANDO...",
                dispatchingBusy: "ENVIANDO...",
                resettingBusy: "RESTABLECIENDO...",
                passphraseLabel: "// CLAVE",
                confirmPassphraseLabel: "// CONFIRMAR CLAVE",
                newPassphraseLabel: "// NUEVA CLAVE",
                sixDigitKeyLabel: "// CÓDIGO DE 6 DÍGITOS",
                forgotPassphrase: "¿OLVIDASTE LA CLAVE?",
                requestResetBody: "Solicita un enlace seguro de recuperación para tu correo operativo.",
                resetInboxTitle: "REVISA TU CORREO",
                resetInboxDetailPrefix: "Si existen credenciales para",
                resetInboxDetailSuffix: "el enlace de recuperación ya está en camino.",
                backToLogin: "VOLVER AL ACCESO",
                continueWithApple: "Continuar con Apple",
                appleSheetTitle: "Iniciar sesión con Apple",
                appleSheetBody: "Usa tu Apple ID para entrar en SpyClash. Solo Apple procesa tu contraseña.",
                appleSheetDismiss: "AHORA NO",
                continueWithGoogle: "CONTINUAR CON GOOGLE",
                emailDivider: "O CON CORREO",
                requestAccessFooter: "SOLICITAR ACCESO",
                loginFooter: "INICIAR SESIÓN",
                passphrasesMismatch: "Las claves no coinciden.",
                recoveryLinkNotice: "Si existen credenciales para ese correo, el enlace de recuperación ya está en camino.",
                passphraseUpdatedNotice: "Clave actualizada. Inicia sesión con la nueva clave.",
                appleMissingToken: "La respuesta de Apple no incluyó un token de acceso.",
                googleMissingToken: "La respuesta de Google no incluyó un token de acceso.",
                chooseNewPassphraseNotice: "Elige una nueva clave para recuperar el acceso.",
                signInToJoinPrefix: "INICIA SESIÓN PARA UNIRTE A",
                emailPlaceholder: "operativo@ejemplo.com"
            )
        case .ru:
            AuthCopy(
                accessTerminal: "ТЕРМИНАЛ ДОСТУПА",
                passphraseRequired: "НУЖЕН ПАРОЛЬ",
                newOperative: "НОВЫЙ ОПЕРАТИВНИК",
                setPassphrase: "УСТАНОВИТЕ ПАРОЛЬ",
                verificationRequired: "НУЖНО ПОДТВЕРЖДЕНИЕ",
                recoveryProtocol: "ПРОТОКОЛ ВОССТАНОВЛЕНИЯ",
                transmissionSent: "ПЕРЕДАЧА ОТПРАВЛЕНА",
                setNewPassphrase: "НОВЫЙ ПАРОЛЬ",
                welcomeBack: "С возвращением",
                joinNetworkTitle: "Войти в сеть",
                createPassphraseTitle: "Создать пароль",
                confirmIdentityTitle: "Подтвердить личность",
                resetPassphraseTitle: "Сбросить пароль",
                checkInboxTitle: "Проверь почту",
                newCredentialsTitle: "Новые ключи",
                emailSubtitle: "Авторизуйся, чтобы продолжить миссию",
                passwordSubtitle: "Последний шаг",
                registerEmailSubtitle: "Создай доступ, чтобы войти в игру",
                registerPasswordSubtitle: "Выбери надежный ключ",
                otpSubtitlePrefix: "Код отправлен на",
                forgotPasswordEmptySubtitle: "Запроси безопасную ссылку восстановления",
                forgotPasswordPrefix: "Ссылка восстановления для",
                resetEmailSentPrefix: "Ссылка восстановления отправлена на",
                resetPasswordSubtitle: "Выбери новый надежный пароль",
                continueAction: "ДАЛЬШЕ",
                unlockAction: "РАЗБЛОКИРОВАТЬ",
                joinNetworkAction: "ВОЙТИ В СЕТЬ",
                createCredentialsAction: "СОЗДАТЬ ДОСТУП",
                verifyEnterAction: "ПОДТВЕРДИТЬ И ВОЙТИ",
                dispatchResetLinkAction: "ОТПРАВИТЬ ССЫЛКУ",
                confirmNewKeyAction: "ПОДТВЕРДИТЬ НОВЫЙ КЛЮЧ",
                authenticatingBusy: "ПРОВЕРКА...",
                recruitingBusy: "РЕГИСТРАЦИЯ...",
                verifyingBusy: "ПОДТВЕРЖДЕНИЕ...",
                dispatchingBusy: "ОТПРАВКА...",
                resettingBusy: "СБРОС...",
                passphraseLabel: "// ПАРОЛЬ",
                confirmPassphraseLabel: "// ПОВТОРИТЕ ПАРОЛЬ",
                newPassphraseLabel: "// НОВЫЙ ПАРОЛЬ",
                sixDigitKeyLabel: "// 6-ЗНАЧНЫЙ КОД",
                forgotPassphrase: "ЗАБЫЛ ПАРОЛЬ?",
                requestResetBody: "Запроси безопасную ссылку восстановления для оперативной почты.",
                resetInboxTitle: "ПРОВЕРЬ ПОЧТУ",
                resetInboxDetailPrefix: "Если доступ существует для",
                resetInboxDetailSuffix: "ссылка восстановления уже в пути.",
                backToLogin: "НАЗАД К ВХОДУ",
                continueWithApple: "Продолжить с Apple",
                appleSheetTitle: "Вход через Apple",
                appleSheetBody: "Войди в SpyClash через Apple ID. Твой пароль обрабатывается только системой Apple.",
                appleSheetDismiss: "НЕ СЕЙЧАС",
                continueWithGoogle: "ПРОДОЛЖИТЬ С GOOGLE",
                emailDivider: "ИЛИ ЧЕРЕЗ EMAIL",
                requestAccessFooter: "ЗАПРОСИТЬ ДОСТУП",
                loginFooter: "ВОЙТИ",
                passphrasesMismatch: "Пароли не совпадают.",
                recoveryLinkNotice: "Если доступ существует для этой почты, ссылка восстановления уже в пути.",
                passphraseUpdatedNotice: "Пароль обновлен. Войди с новым ключом.",
                appleMissingToken: "Apple не вернул access token.",
                googleMissingToken: "Google не вернул access token.",
                chooseNewPassphraseNotice: "Выбери новый пароль, чтобы восстановить доступ.",
                signInToJoinPrefix: "ВОЙДИ, ЧТОБЫ ПРИСОЕДИНИТЬСЯ К",
                emailPlaceholder: "operative@example.com"
            )
        }
    }

    var qr: QRInviteCopy {
        switch self {
        case .en:
            QRInviteCopy(
                roomBeaconEyebrow: "// ROOM BEACON",
                roomBeaconSubtitle: "Scan to join this room",
                transmitInvite: "TRANSMIT INVITE",
                close: "CLOSE",
                scanEyebrow: "// QR SCAN",
                scanTitle: "Room Uplink",
                alignRoomBeacon: "ALIGN ROOM BEACON",
                checkingCamera: "CHECKING CAMERA",
                cameraPreparing: "Preparing secure camera channel.",
                cameraLocked: "CAMERA LOCKED",
                cameraLockedDetail: "Enable camera access in Settings to scan room QR codes.",
                cancel: "CANCEL",
                joiningPrefix: "JOINING",
                roomLinked: "ROOM LINKED",
                roomNotFound: "ROOM NOT FOUND",
                invalidCode: "INVALID ROOM QR"
            )
        case .es:
            QRInviteCopy(
                roomBeaconEyebrow: "// BALIZA DE SALA",
                roomBeaconSubtitle: "Escanea para unirte a esta sala",
                transmitInvite: "TRANSMITIR INVITE",
                close: "CERRAR",
                scanEyebrow: "// ESCANEO QR",
                scanTitle: "Uplink de Sala",
                alignRoomBeacon: "ALINEA LA BALIZA",
                checkingCamera: "COMPROBANDO CAMARA",
                cameraPreparing: "Preparando canal seguro de camara.",
                cameraLocked: "CAMARA BLOQUEADA",
                cameraLockedDetail: "Activa la camara en Ajustes para escanear QR de sala.",
                cancel: "CANCELAR",
                joiningPrefix: "UNIENDO",
                roomLinked: "SALA VINCULADA",
                roomNotFound: "SALA NO ENCONTRADA",
                invalidCode: "QR DE SALA INVALIDO"
            )
        case .ru:
            QRInviteCopy(
                roomBeaconEyebrow: "// МАЯК КОМНАТЫ",
                roomBeaconSubtitle: "Сканируй, чтобы войти в комнату",
                transmitInvite: "ПЕРЕДАТЬ ИНВАЙТ",
                close: "ЗАКРЫТЬ",
                scanEyebrow: "// QR СКАН",
                scanTitle: "Канал комнаты",
                alignRoomBeacon: "НАВЕДИ НА МАЯК",
                checkingCamera: "ПРОВЕРКА КАМЕРЫ",
                cameraPreparing: "Готовим защищенный канал камеры.",
                cameraLocked: "КАМЕРА ЗАБЛОКИРОВАНА",
                cameraLockedDetail: "Разреши камеру в настройках, чтобы сканировать QR комнаты.",
                cancel: "ОТМЕНА",
                joiningPrefix: "ВХОДИМ",
                roomLinked: "КОМНАТА ПОДКЛЮЧЕНА",
                roomNotFound: "КОМНАТА НЕ НАЙДЕНА",
                invalidCode: "НЕВЕРНЫЙ QR КОМНАТЫ"
            )
        }
    }

    var profile: ProfileCopy {
        switch self {
        case .en:
            ProfileCopy(
                eyebrow: "// PROFILE",
                logOut: "LOG OUT",
                deleteDialogTitle: "DELETE ACCOUNT",
                deleteDialogAction: "DELETE ACCOUNT",
                cancel: "CANCEL",
                deleteDialogMessage: "This permanently deletes your profile, game history, custom packs, and social data. Limited security and moderation records may be retained where legally required.",
                operativeID: "OPERATIVE ID",
                selectAvatar: "// SELECT AVATAR",
                displayName: "// DISPLAY NAME",
                callSignPlaceholder: "CALLSIGN",
                saveProfile: "SAVE PROFILE",
                savingProfile: "SAVING PROFILE...",
                archive: "// ARCHIVE",
                games: "GAMES",
                wins: "WINS",
                rate: "RATE",
                rating: "RATING",
                spy: "SPY",
                detective: "DETECT",
                leaderboard: "LEADERBOARD",
                history: "HISTORY",
                languageLabel: "// LANGUAGE",
                legal: "// LEGAL",
                legalHint: "Review the same field rules and privacy policy from the web command center.",
                privacy: "PRIVACY",
                terms: "TERMS",
                dangerZone: "// DANGER ZONE",
                dangerBody: "Deleting the account erases profile data, custom packs and archive entries.",
                deleteAccount: "DELETE ACCOUNT",
                deletingAccount: "DELETING ACCOUNT...",
                saved: "SAVED"
            )
        case .es:
            ProfileCopy(
                eyebrow: "// PERFIL",
                logOut: "CERRAR SESION",
                deleteDialogTitle: "ELIMINAR CUENTA",
                deleteDialogAction: "ELIMINAR CUENTA",
                cancel: "CANCELAR",
                deleteDialogMessage: "Esto elimina permanentemente tu perfil, historial de partidas, paquetes personalizados y datos sociales. Algunos registros de seguridad y moderacion pueden conservarse cuando la ley lo exija.",
                operativeID: "ID OPERATIVO",
                selectAvatar: "// ELEGIR AVATAR",
                displayName: "// NOMBRE VISIBLE",
                callSignPlaceholder: "INDICATIVO",
                saveProfile: "GUARDAR PERFIL",
                savingProfile: "GUARDANDO PERFIL...",
                archive: "// ARCHIVO",
                games: "PARTIDAS",
                wins: "VICTORIAS",
                rate: "TASA",
                rating: "RATING",
                spy: "ESPIA",
                detective: "DETECT",
                leaderboard: "CLASIFICACION",
                history: "HISTORIAL",
                languageLabel: "// IDIOMA",
                legal: "// LEGAL",
                legalHint: "Revisa las mismas reglas y politica de privacidad del centro web.",
                privacy: "PRIVACIDAD",
                terms: "TERMINOS",
                dangerZone: "// ZONA DE PELIGRO",
                dangerBody: "Eliminar la cuenta borra el perfil, los paquetes personalizados y el archivo.",
                deleteAccount: "ELIMINAR CUENTA",
                deletingAccount: "ELIMINANDO CUENTA...",
                saved: "GUARDADO"
            )
        case .ru:
            ProfileCopy(
                eyebrow: "// ПРОФИЛЬ",
                logOut: "ВЫЙТИ",
                deleteDialogTitle: "УДАЛИТЬ АККАУНТ",
                deleteDialogAction: "УДАЛИТЬ АККАУНТ",
                cancel: "ОТМЕНА",
                deleteDialogMessage: "Это навсегда удалит профиль, историю игр, пользовательские паки и социальные данные. Ограниченные записи безопасности и модерации могут храниться, если этого требует закон.",
                operativeID: "ID ОПЕРАТИВНИКА",
                selectAvatar: "// ВЫБОР АВАТАРА",
                displayName: "// ИМЯ НА ЭКРАНЕ",
                callSignPlaceholder: "ПОЗЫВНОЙ",
                saveProfile: "СОХРАНИТЬ ПРОФИЛЬ",
                savingProfile: "СОХРАНЕНИЕ ПРОФИЛЯ...",
                archive: "// АРХИВ",
                games: "ИГРЫ",
                wins: "ПОБЕДЫ",
                rate: "ВИНРЕЙТ",
                rating: "РЕЙТИНГ",
                spy: "ШПИОН",
                detective: "ДЕТЕКТ",
                leaderboard: "РЕЙТИНГ",
                history: "ИСТОРИЯ",
                languageLabel: "// ЯЗЫК",
                legal: "// ПРАВИЛА",
                legalHint: "Открой те же правила и политику приватности, что и в веб-версии.",
                privacy: "ПРИВАТНОСТЬ",
                terms: "УСЛОВИЯ",
                dangerZone: "// ОПАСНАЯ ЗОНА",
                dangerBody: "Удаление аккаунта стирает профиль, пользовательские паки и архив.",
                deleteAccount: "УДАЛИТЬ АККАУНТ",
                deletingAccount: "УДАЛЕНИЕ АККАУНТА...",
                saved: "СОХРАНЕНО"
            )
        }
    }

    var history: HistoryCopy {
        switch self {
        case .en:
            HistoryCopy(
                eyebrow: "// HISTORY",
                status: "ARCHIVE",
                title: "ARCHIVE",
                subtitle: "MISSION HISTORY",
                games: "GAMES",
                wins: "WINS",
                rate: "RATE",
                loading: "LOADING ARCHIVE",
                empty: "NO ARCHIVE ENTRIES",
                operatives: "OPERATIVES",
                roomFallback: "ROOM",
                categoryFallback: "CLASSIC",
                unknownRole: "UNKNOWN",
                spyRole: "SPY",
                detectiveRole: "DETECTIVE",
                win: "WIN",
                loss: "LOSS"
            )
        case .es:
            HistoryCopy(
                eyebrow: "// HISTORIAL",
                status: "ARCHIVO",
                title: "ARCHIVO",
                subtitle: "HISTORIAL DE MISIONES",
                games: "PARTIDAS",
                wins: "VICTORIAS",
                rate: "TASA",
                loading: "CARGANDO ARCHIVO",
                empty: "SIN ENTRADAS",
                operatives: "OPERATIVOS",
                roomFallback: "SALA",
                categoryFallback: "CLASICO",
                unknownRole: "DESCONOCIDO",
                spyRole: "ESPIA",
                detectiveRole: "DETECTIVE",
                win: "VICTORIA",
                loss: "DERROTA"
            )
        case .ru:
            HistoryCopy(
                eyebrow: "// ИСТОРИЯ",
                status: "АРХИВ",
                title: "АРХИВ",
                subtitle: "ИСТОРИЯ МИССИЙ",
                games: "ИГРЫ",
                wins: "ПОБЕДЫ",
                rate: "ВИНРЕЙТ",
                loading: "ЗАГРУЗКА АРХИВА",
                empty: "В АРХИВЕ ПУСТО",
                operatives: "ОПЕРАТИВНИКОВ",
                roomFallback: "КОМНАТА",
                categoryFallback: "КЛАССИКА",
                unknownRole: "НЕИЗВЕСТНО",
                spyRole: "ШПИОН",
                detectiveRole: "ДЕТЕКТИВ",
                win: "ПОБЕДА",
                loss: "ПОРАЖЕНИЕ"
            )
        }
    }

    var leaderboard: LeaderboardCopy {
        switch self {
        case .en:
            LeaderboardCopy(
                eyebrow: "// LEADERBOARD",
                status: "RANKED",
                title: "RANKED",
                subtitle: "GLOBAL OPERATIVES",
                loading: "SYNCING RANKS",
                empty: "NO RANKED DATA",
                rankHeader: "RK",
                playerHeader: "PLAYER",
                ratingHeader: "RATING",
                winsHeader: "W",
                games: "GAMES",
                winRate: "WIN RATE"
            )
        case .es:
            LeaderboardCopy(
                eyebrow: "// CLASIFICACION",
                status: "RANKED",
                title: "RANKED",
                subtitle: "OPERATIVOS GLOBALES",
                loading: "SINCRONIZANDO RANGOS",
                empty: "SIN DATOS RANKED",
                rankHeader: "RK",
                playerHeader: "JUGADOR",
                ratingHeader: "RATING",
                winsHeader: "V",
                games: "PARTIDAS",
                winRate: "TASA VICT."
            )
        case .ru:
            LeaderboardCopy(
                eyebrow: "// РЕЙТИНГ",
                status: "РАНГ",
                title: "РАНГ",
                subtitle: "ГЛОБАЛЬНЫЕ ОПЕРАТИВНИКИ",
                loading: "СИНХРОНИЗАЦИЯ РАНГОВ",
                empty: "РАНГОВЫХ ДАННЫХ НЕТ",
                rankHeader: "РК",
                playerHeader: "ИГРОК",
                ratingHeader: "РЕЙТ",
                winsHeader: "П",
                games: "ИГР",
                winRate: "ВИНРЕЙТ"
            )
        }
    }

    var wordPacks: WordPacksCopy {
        switch self {
        case .en:
            WordPacksCopy(
                eyebrow: "// WORD PACKS",
                status: "ARMORY",
                title: "ARMORY",
                countSuffix: "CUSTOM PACKS",
                loading: "LOADING PACKS",
                emptyTitle: "NO CUSTOM PACKS",
                emptyBody: "Create a private word pool for room games and local sessions.",
                createFirstPack: "CREATE FIRST PACK",
                customFallback: "CUSTOM",
                wordsSuffix: "WORDS",
                removingPack: "REMOVING PACK",
                deleteDialogTitle: "DELETE WORD PACK",
                deleteActionPrefix: "DELETE",
                cancel: "CANCEL",
                deleteMessagePrefix: "This removes",
                deleteMessageSuffix: "from your Base44 armory.",
                editor: WordPackEditorCopy(
                    eyebrow: "// ARMORY EDITOR",
                    newTitle: "NEW WORD PACK",
                    editTitle: "EDIT WORD PACK",
                    wordsMetric: "WORDS",
                    modeMetric: "MODE",
                    createMode: "CREATE",
                    updateMode: "UPDATE",
                    aiGeneration: "// AI GENERATION",
                    themePlaceholder: "Theme in any language",
                    wordsToGenerate: "WORDS TO GENERATE",
                    generateWords: "GENERATE WORDS",
                    aiDraftHint: "AI fills the draft only. Review and edit before saving.",
                    packNameLabel: "// PACK NAME",
                    packNamePlaceholder: "Cities, movies, family chaos...",
                    categoryLabel: "// CATEGORY",
                    categoryPlaceholder: "Custom",
                    wordsLabel: "// WORDS",
                    wordsInputHint: "COMMA OR NEW LINE",
                    emptyWordsHint: "Add at least two playable words.",
                    createPack: "CREATE PACK",
                    savePack: "SAVE PACK",
                    signInRequired: "SIGN IN REQUIRED",
                    packNeedsNameAndWords: "PACK NEEDS A NAME AND AT LEAST TWO WORDS",
                    enterThemeFirst: "ENTER A THEME FIRST",
                    aiReady: "AI READY",
                    wordsUnit: "WORDS",
                    of: "OF",
                    today: "TODAY",
                    previewSaved: "PREVIEW SAVED"
                )
            )
        case .es:
            WordPacksCopy(
                eyebrow: "// PACKS",
                status: "ARMERIA",
                title: "ARMERIA",
                countSuffix: "PACKS PROPIOS",
                loading: "CARGANDO PACKS",
                emptyTitle: "SIN PACKS PROPIOS",
                emptyBody: "Crea un banco privado de palabras para salas y partidas locales.",
                createFirstPack: "CREAR PRIMER PACK",
                customFallback: "PROPIO",
                wordsSuffix: "PALABRAS",
                removingPack: "ELIMINANDO PACK",
                deleteDialogTitle: "ELIMINAR PACK",
                deleteActionPrefix: "ELIMINAR",
                cancel: "CANCELAR",
                deleteMessagePrefix: "Esto elimina",
                deleteMessageSuffix: "de tu armeria Base44.",
                editor: WordPackEditorCopy(
                    eyebrow: "// EDITOR DE ARMERIA",
                    newTitle: "NUEVO PACK",
                    editTitle: "EDITAR PACK",
                    wordsMetric: "PALABRAS",
                    modeMetric: "MODO",
                    createMode: "CREAR",
                    updateMode: "ACTUALIZAR",
                    aiGeneration: "// GENERACION IA",
                    themePlaceholder: "Tema en cualquier idioma",
                    wordsToGenerate: "PALABRAS A GENERAR",
                    generateWords: "GENERAR PALABRAS",
                    aiDraftHint: "La IA solo llena el borrador. Revisa y edita antes de guardar.",
                    packNameLabel: "// NOMBRE DEL PACK",
                    packNamePlaceholder: "Ciudades, peliculas, caos familiar...",
                    categoryLabel: "// CATEGORIA",
                    categoryPlaceholder: "Propio",
                    wordsLabel: "// PALABRAS",
                    wordsInputHint: "COMA O LINEA NUEVA",
                    emptyWordsHint: "Anade al menos dos palabras jugables.",
                    createPack: "CREAR PACK",
                    savePack: "GUARDAR PACK",
                    signInRequired: "SESION REQUERIDA",
                    packNeedsNameAndWords: "EL PACK NECESITA NOMBRE Y AL MENOS DOS PALABRAS",
                    enterThemeFirst: "ESCRIBE UN TEMA PRIMERO",
                    aiReady: "IA LISTA",
                    wordsUnit: "PALABRAS",
                    of: "DE",
                    today: "HOY",
                    previewSaved: "PREVIEW GUARDADO"
                )
            )
        case .ru:
            WordPacksCopy(
                eyebrow: "// ПАКИ СЛОВ",
                status: "АРСЕНАЛ",
                title: "АРСЕНАЛ",
                countSuffix: "СВОИХ ПАКОВ",
                loading: "ЗАГРУЗКА ПАКОВ",
                emptyTitle: "СВОИХ ПАКОВ НЕТ",
                emptyBody: "Создай приватный набор слов для комнат и локальных партий.",
                createFirstPack: "СОЗДАТЬ ПЕРВЫЙ ПАК",
                customFallback: "СВОЙ",
                wordsSuffix: "СЛОВ",
                removingPack: "УДАЛЕНИЕ ПАКА",
                deleteDialogTitle: "УДАЛИТЬ ПАК",
                deleteActionPrefix: "УДАЛИТЬ",
                cancel: "ОТМЕНА",
                deleteMessagePrefix: "Это удалит",
                deleteMessageSuffix: "из твоего арсенала Base44.",
                editor: WordPackEditorCopy(
                    eyebrow: "// РЕДАКТОР АРСЕНАЛА",
                    newTitle: "НОВЫЙ ПАК",
                    editTitle: "РЕДАКТИРОВАТЬ ПАК",
                    wordsMetric: "СЛОВА",
                    modeMetric: "РЕЖИМ",
                    createMode: "СОЗДАТЬ",
                    updateMode: "ОБНОВИТЬ",
                    aiGeneration: "// AI-ГЕНЕРАЦИЯ",
                    themePlaceholder: "Тема на любом языке",
                    wordsToGenerate: "СЛОВ ДЛЯ ГЕНЕРАЦИИ",
                    generateWords: "СГЕНЕРИРОВАТЬ СЛОВА",
                    aiDraftHint: "AI заполняет только черновик. Проверь и отредактируй перед сохранением.",
                    packNameLabel: "// НАЗВАНИЕ ПАКА",
                    packNamePlaceholder: "Города, фильмы, семейный хаос...",
                    categoryLabel: "// КАТЕГОРИЯ",
                    categoryPlaceholder: "Свой",
                    wordsLabel: "// СЛОВА",
                    wordsInputHint: "ЗАПЯТАЯ ИЛИ НОВАЯ СТРОКА",
                    emptyWordsHint: "Добавь минимум два игровых слова.",
                    createPack: "СОЗДАТЬ ПАК",
                    savePack: "СОХРАНИТЬ ПАК",
                    signInRequired: "НУЖЕН ВХОД",
                    packNeedsNameAndWords: "ПАКУ НУЖНЫ НАЗВАНИЕ И МИНИМУМ ДВА СЛОВА",
                    enterThemeFirst: "СНАЧАЛА ВВЕДИ ТЕМУ",
                    aiReady: "AI ГОТОВ",
                    wordsUnit: "СЛОВ",
                    of: "ИЗ",
                    today: "СЕГОДНЯ",
                    previewSaved: "PREVIEW СОХРАНЕН"
                )
            )
        }
    }

    var home: HomeCopy {
        switch self {
        case .en:
            HomeCopy(
                eyebrow: "// HOME",
                operativeLabel: "OPERATIVE",
                unknownOperative: "UNKNOWN",
                missionControl: "MISSION CONTROL",
                createOnlineRoom: "CREATE ONLINE ROOM",
                roomKeyPlaceholder: "ROOM KEY",
                scanQR: "SCAN QR",
                localPassMode: "LOCAL PASS MODE",
                ranked: "RANKED",
                archive: "ARCHIVE",
                activeRoom: "// ACTIVE ROOM",
                liveSignals: "// LIVE SIGNALS",
                recentFiles: "// RECENT FILES",
                noArchiveEntries: "NO ARCHIVE ENTRIES",
                openArchive: "OPEN ARCHIVE",
                roomLabel: "ROOM",
                operatives: "OPERATIVES",
                unknown: "UNKNOWN",
                win: "WIN",
                loss: "LOSS",
                spyRole: "SPY",
                detectiveRole: "DETECTIVE",
                roomNotFound: "ROOM NOT FOUND",
                roomReadySuffix: "READY",
                waiting: "WAITING",
                readyVoting: "READY CHECK",
                roulette: "ROULETTE",
                playing: "PLAYING",
                finished: "FINISHED"
            )
        case .es:
            HomeCopy(
                eyebrow: "// INICIO",
                operativeLabel: "OPERATIVO",
                unknownOperative: "DESCONOCIDO",
                missionControl: "CONTROL DE MISIÓN",
                createOnlineRoom: "CREAR SALA EN LÍNEA",
                roomKeyPlaceholder: "CÓDIGO DE SALA",
                scanQR: "ESCANEAR QR",
                localPassMode: "MODO LOCAL",
                ranked: "CLASIFICACIÓN",
                archive: "ARCHIVO",
                activeRoom: "// SALA ACTIVA",
                liveSignals: "// SEÑALES EN VIVO",
                recentFiles: "// ARCHIVOS RECIENTES",
                noArchiveEntries: "ARCHIVO VACÍO",
                openArchive: "ABRIR ARCHIVO",
                roomLabel: "SALA",
                operatives: "OPERATIVOS",
                unknown: "DESCONOCIDO",
                win: "VICTORIA",
                loss: "DERROTA",
                spyRole: "ESPÍA",
                detectiveRole: "DETECTIVE",
                roomNotFound: "SALA NO ENCONTRADA",
                roomReadySuffix: "LISTA",
                waiting: "ESPERANDO",
                readyVoting: "CONFIRMACIÓN",
                roulette: "RULETA",
                playing: "EN JUEGO",
                finished: "FINALIZADA"
            )
        case .ru:
            HomeCopy(
                eyebrow: "// ГЛАВНАЯ",
                operativeLabel: "ОПЕРАТИВНИК",
                unknownOperative: "НЕИЗВЕСТНО",
                missionControl: "ЦЕНТР МИССИИ",
                createOnlineRoom: "СОЗДАТЬ ОНЛАЙН-КОМНАТУ",
                roomKeyPlaceholder: "КОД КОМНАТЫ",
                scanQR: "СКАН QR",
                localPassMode: "ЛОКАЛЬНЫЙ РЕЖИМ",
                ranked: "РАНГ",
                archive: "АРХИВ",
                activeRoom: "// АКТИВНАЯ КОМНАТА",
                liveSignals: "// ЖИВЫЕ СИГНАЛЫ",
                recentFiles: "// ПОСЛЕДНИЕ ФАЙЛЫ",
                noArchiveEntries: "В АРХИВЕ ПУСТО",
                openArchive: "ОТКРЫТЬ АРХИВ",
                roomLabel: "КОМНАТА",
                operatives: "ОПЕРАТИВНИКОВ",
                unknown: "НЕИЗВЕСТНО",
                win: "ПОБЕДА",
                loss: "ПОРАЖЕНИЕ",
                spyRole: "ШПИОН",
                detectiveRole: "ДЕТЕКТИВ",
                roomNotFound: "КОМНАТА НЕ НАЙДЕНА",
                roomReadySuffix: "ГОТОВА",
                waiting: "ОЖИДАНИЕ",
                readyVoting: "ГОТОВНОСТЬ",
                roulette: "РУЛЕТКА",
                playing: "В ИГРЕ",
                finished: "ЗАВЕРШЕНА"
            )
        }
    }

    var localGame: LocalGameCopy {
        switch self {
        case .en:
            LocalGameCopy(
                eyebrow: "// LOCAL GAME",
                setupStatus: "OFFLINE",
                cardsStatus: "DEALING",
                playingStatus: "LIVE",
                votingStatus: "VOTE",
                spyGuessStatus: "GUESS",
                resultsStatus: "ARCHIVE",
                passModeTitle: "PASS MODE",
                localOperatives: "LOCAL OPERATIVES",
                operativeNamePlaceholder: "OPERATIVE NAME",
                addPlayer: "ADD",
                dropPlayer: "DROP",
                duration: "DURATION",
                minuteSuffix: "MIN",
                wordPool: "WORD POOL",
                wordsSuffix: "WORDS",
                mode: "MODE",
                questionsMode: "QUESTIONS",
                classicMode: "ASSOCIATIONS",
                wordSource: "WORD SOURCE",
                builtinIntel: "BUILT-IN INTEL",
                armLocalGame: "ARM LOCAL GAME",
                passPhone: "PASS PHONE TO THIS PLAYER",
                lockScreen: "LOCK SCREEN BEFORE PASSING",
                revealCard: "REVEAL CARD",
                beginTimer: "BEGIN TIMER",
                nextPlayer: "NEXT PLAYER",
                timerEyebrow: "// TIMER",
                wordHidden: "WORD IS HIDDEN UNTIL THE ARCHIVE OPENS",
                questionVector: "// QUESTION VECTOR",
                asker: "ASKER",
                answer: "ANSWER",
                pending: "PENDING",
                nextQuestion: "NEXT QUESTION",
                callVote: "CALL VOTE",
                finalAccusation: "// FINAL ACCUSATION",
                whoIsSpy: "WHO IS THE SPY?",
                archive: "// ARCHIVE",
                spyWins: "SPY WINS",
                detectivesWin: "DETECTIVES WIN",
                wordLabel: "WORD",
                spyLabel: "SPY",
                newRound: "NEW ROUND",
                returnSetup: "RETURN SETUP",
                needTwoOperatives: "NEED AT LEAST 2 OPERATIVES",
                tapToReveal: "TAP TO REVEAL",
                youAreSpy: "YOU ARE THE SPY",
                youAreDetective: "YOU ARE DETECTIVE",
                categoryLabel: "CATEGORY",
                spyHint: "Learn the word. Do not get caught.",
                secretWord: "SECRET WORD",
                fallbackPlayer: "Player"
            )
        case .es:
            LocalGameCopy(
                eyebrow: "// PARTIDA LOCAL",
                setupStatus: "OFFLINE",
                cardsStatus: "REPARTO",
                playingStatus: "EN VIVO",
                votingStatus: "VOTO",
                spyGuessStatus: "ADIVINA",
                resultsStatus: "ARCHIVO",
                passModeTitle: "MODO PASAR",
                localOperatives: "OPERATIVOS LOCALES",
                operativeNamePlaceholder: "NOMBRE OPERATIVO",
                addPlayer: "ANADIR",
                dropPlayer: "QUITAR",
                duration: "DURACION",
                minuteSuffix: "MIN",
                wordPool: "BANCO DE PALABRAS",
                wordsSuffix: "PALABRAS",
                mode: "MODO",
                questionsMode: "PREGUNTAS",
                classicMode: "ASOCIACIONES",
                wordSource: "FUENTE DE PALABRAS",
                builtinIntel: "INTEL INTEGRADA",
                armLocalGame: "ARMAR PARTIDA LOCAL",
                passPhone: "PASA EL TELEFONO A ESTE JUGADOR",
                lockScreen: "BLOQUEA LA PANTALLA ANTES DE PASAR",
                revealCard: "REVELAR CARTA",
                beginTimer: "INICIAR TIMER",
                nextPlayer: "SIGUIENTE JUGADOR",
                timerEyebrow: "// TIMER",
                wordHidden: "LA PALABRA SE OCULTA HASTA ABRIR EL ARCHIVO",
                questionVector: "// VECTOR DE PREGUNTA",
                asker: "PREGUNTA",
                answer: "RESPONDE",
                pending: "PENDIENTE",
                nextQuestion: "SIGUIENTE PREGUNTA",
                callVote: "LLAMAR VOTO",
                finalAccusation: "// ACUSACION FINAL",
                whoIsSpy: "QUIEN ES EL ESPIA?",
                archive: "// ARCHIVO",
                spyWins: "GANA EL ESPIA",
                detectivesWin: "GANAN DETECTIVES",
                wordLabel: "PALABRA",
                spyLabel: "ESPIA",
                newRound: "NUEVA RONDA",
                returnSetup: "VOLVER A SETUP",
                needTwoOperatives: "NECESITAS AL MENOS 2 OPERATIVOS",
                tapToReveal: "TOCA PARA REVELAR",
                youAreSpy: "ERES EL ESPIA",
                youAreDetective: "ERES DETECTIVE",
                categoryLabel: "CATEGORIA",
                spyHint: "Aprende la palabra. No te dejes atrapar.",
                secretWord: "PALABRA SECRETA",
                fallbackPlayer: "Jugador"
            )
        case .ru:
            LocalGameCopy(
                eyebrow: "// ЛОКАЛЬНАЯ ИГРА",
                setupStatus: "ОФЛАЙН",
                cardsStatus: "РАЗДАЧА",
                playingStatus: "LIVE",
                votingStatus: "ГОЛОС",
                spyGuessStatus: "ДОГАДКА",
                resultsStatus: "АРХИВ",
                passModeTitle: "PASS-РЕЖИМ",
                localOperatives: "ЛОКАЛЬНЫЕ ОПЕРАТИВНИКИ",
                operativeNamePlaceholder: "ИМЯ ОПЕРАТИВНИКА",
                addPlayer: "ДОБАВИТЬ",
                dropPlayer: "УБРАТЬ",
                duration: "ДЛИТЕЛЬНОСТЬ",
                minuteSuffix: "МИН",
                wordPool: "ПУЛ СЛОВ",
                wordsSuffix: "СЛОВ",
                mode: "РЕЖИМ",
                questionsMode: "ВОПРОСЫ",
                classicMode: "АССОЦИАЦИИ",
                wordSource: "ИСТОЧНИК СЛОВ",
                builtinIntel: "ВСТРОЕННЫЙ INTEL",
                armLocalGame: "ЗАПУСТИТЬ ЛОКАЛЬНУЮ ИГРУ",
                passPhone: "ПЕРЕДАЙ ТЕЛЕФОН ЭТОМУ ИГРОКУ",
                lockScreen: "ЗАБЛОКИРУЙ ЭКРАН ПЕРЕД ПЕРЕДАЧЕЙ",
                revealCard: "ОТКРЫТЬ КАРТУ",
                beginTimer: "ЗАПУСТИТЬ ТАЙМЕР",
                nextPlayer: "СЛЕДУЮЩИЙ ИГРОК",
                timerEyebrow: "// ТАЙМЕР",
                wordHidden: "СЛОВО СКРЫТО ДО ОТКРЫТИЯ АРХИВА",
                questionVector: "// ВЕКТОР ВОПРОСА",
                asker: "СПРАШИВАЕТ",
                answer: "ОТВЕЧАЕТ",
                pending: "ОЖИДАНИЕ",
                nextQuestion: "СЛЕДУЮЩИЙ ВОПРОС",
                callVote: "НАЧАТЬ ГОЛОС",
                finalAccusation: "// ФИНАЛЬНОЕ ОБВИНЕНИЕ",
                whoIsSpy: "КТО ШПИОН?",
                archive: "// АРХИВ",
                spyWins: "ШПИОН ПОБЕДИЛ",
                detectivesWin: "ДЕТЕКТИВЫ ПОБЕДИЛИ",
                wordLabel: "СЛОВО",
                spyLabel: "ШПИОН",
                newRound: "НОВЫЙ РАУНД",
                returnSetup: "ВЕРНУТЬ НАСТРОЙКИ",
                needTwoOperatives: "НУЖНО МИНИМУМ 2 ОПЕРАТИВНИКА",
                tapToReveal: "НАЖМИ, ЧТОБЫ ОТКРЫТЬ",
                youAreSpy: "ТЫ ШПИОН",
                youAreDetective: "ТЫ ДЕТЕКТИВ",
                categoryLabel: "КАТЕГОРИЯ",
                spyHint: "Запомни слово. Не попадись.",
                secretWord: "СЕКРЕТНОЕ СЛОВО",
                fallbackPlayer: "Игрок"
            )
        }
    }

    var game: GameCopy {
        switch self {
        case .en:
            GameCopy(
                eyebrow: "// ROOM",
                standby: "STANDBY",
                lobby: "// LOBBY",
                hostConsoleReady: "HOST CONSOLE READY",
                waitingForHost: "WAITING FOR HOST",
                minimumOperativesSuffix: "MINIMUM OPERATIVES",
                readyCheck: "// READY CHECK",
                operativeConfirmed: "OPERATIVE CONFIRMED",
                areYouReady: "ARE YOU READY?",
                operativesReadySuffix: "OPERATIVES READY",
                readyConfirmed: "READY CONFIRMED",
                confirmReady: "CONFIRM READY",
                startGame: "START GAME",
                returnToLobby: "RETURN TO LOBBY",
                leaveRoom: "LEAVE ROOM",
                roulette: "// ROULETTE",
                selecting: "SELECTING",
                firstQuestionVector: "FIRST QUESTION VECTOR",
                armingFinalPayload: "ARMING FINAL PAYLOAD",
                waitingForHostSignal: "WAITING FOR HOST SIGNAL",
                result: "// RESULT",
                spyWins: "SPY WINS",
                detectivesWin: "DETECTIVES WIN",
                wordLabel: "WORD",
                spyLabel: "SPY",
                classified: "CLASSIFIED",
                roomKey: "// ROOM KEY",
                activeMetric: "ACTIVE",
                questionsMetric: "QUESTIONS",
                votesMetric: "VOTES",
                hostConsole: "// HOST CONSOLE",
                missionConfig: "// MISSION CONFIG",
                mode: "MODE",
                questionsMode: "QUESTIONS",
                associationsMode: "ASSOCIATIONS",
                questionsSubtitle: "Directed question chain with eight tactical prompts.",
                associationsSubtitle: "Spin the speaker and follow the association trail.",
                duration: "DURATION",
                minuteSuffix: "MIN",
                wordSource: "WORD SOURCE",
                builtinIntel: "BUILT-IN INTEL",
                syncingWordPacks: "SYNCING WORD PACKS",
                customPacksAvailableSuffix: "CUSTOM PACKS AVAILABLE",
                wordsSuffix: "WORDS",
                customPackUnavailable: "CUSTOM PACK UNAVAILABLE",
                operatives: "// OPERATIVES",
                outBadge: "OUT",
                hostBadge: "HOST",
                askBadge: "ASK",
                voteBadge: "VOTE",
                shareRoomQR: "SHARE ROOM QR",
                readyCheckAction: "READY CHECK",
                startNow: "START NOW",
                noActiveRoom: "NO ACTIVE ROOM",
                openHome: "OPEN HOME",
                dealing: "DEALING",
                voting: "VOTING",
                results: "RESULTS",
                waiting: "WAITING",
                readyVoting: "READY CHECK",
                playing: "PLAYING",
                finished: "FINISHED",
                modeSynced: "MODE SYNCED",
                readyCheckSent: "READY CHECK SENT",
                lobbyRestored: "LOBBY RESTORED",
                roomSynced: "ROOM SYNCED",
                missionTimer: "// MISSION TIMER",
                timeUp: "TIME UP",
                liveStatus: "LIVE",
                callFinalVote: "CALL THE FINAL VOTE",
                timerHintLive: "ASK, DEFLECT, WATCH FOR PATTERNS",
                roleCard: "// ROLE CARD",
                tapEyeToReveal: "TAP EYE TO REVEAL",
                cardCheck: "// CARD CHECK",
                cardConfirmed: "CARD CONFIRMED",
                readYourRole: "READ YOUR ROLE",
                readyShort: "READY",
                waitShort: "WAIT",
                cardTimerHint: "Timer starts when every operative confirms their role card.",
                waitingForTeam: "WAITING FOR TEAM",
                confirmCardRead: "CONFIRM CARD READ",
                associationDrum: "// ASSOCIATION DRUM",
                spinToStart: "SPIN TO START",
                roundLabel: "ROUND",
                sayOneAssociation: "SAY ONE ASSOCIATION",
                questionVector: "// QUESTION VECTOR",
                asker: "ASKER",
                answer: "ANSWER",
                pending: "PENDING",
                voteProtocol: "// VOTE PROTOCOL",
                whoIsSpy: "WHO IS THE SPY?",
                questionCycleComplete: "QUESTION CYCLE COMPLETE",
                requestVoteHint: "Request a vote to move the room into final accusation.",
                spectatorVoteHint: "You are spectating. Active operatives will vote.",
                voteLockedPrefix: "VOTE LOCKED",
                playAgainEyebrow: "// PLAY AGAIN",
                teamReadyAnotherRun: "TEAM READY FOR ANOTHER RUN",
                voteForNewGame: "VOTE FOR NEW GAME",
                replayVoteLocked: "REPLAY VOTE LOCKED",
                playAgain: "PLAY AGAIN",
                backToLobby: "BACK TO LOBBY",
                waitingHostResetLobby: "WAITING FOR HOST TO RESET LOBBY",
                guessWord: "GUESS WORD",
                nextAssociation: "NEXT ASSOCIATION",
                nextQuestion: "NEXT QUESTION",
                votingOpen: "VOTING OPEN",
                requestVotePrefix: "REQUEST VOTE",
                spectatorMode: "SPECTATOR MODE",
                spectatorSubtitle: "Watch the table. Your vote is locked out.",
                youAreSpy: "YOU ARE THE SPY",
                youAreDetective: "YOU ARE DETECTIVE",
                categoryLabel: "Category",
                classicCategory: "CLASSIC",
                secretWord: "SECRET WORD",
                readyRemoved: "READY REMOVED",
                readyLocked: "READY LOCKED",
                rouletteArmed: "ROULETTE ARMED",
                gameReady: "GAME READY",
                associationSpun: "ASSOCIATION SPUN",
                questionSent: "QUESTION SENT",
                cardConfirmedStatus: "CARD CONFIRMED",
                voteRequestedStatus: "VOTE REQUESTED",
                voteLockedStatus: "VOTE LOCKED",
                spyGuessLocked: "SPY GUESS LOCKED",
                spyGuessEyebrow: "// SPY GUESS",
                chooseWord: "CHOOSE THE WORD",
                spyGuessHint: "A correct guess ends the match for the spy. A wrong guess hands the file to the detectives."
            )
        case .es:
            GameCopy(
                eyebrow: "// SALA",
                standby: "STANDBY",
                lobby: "// LOBBY",
                hostConsoleReady: "CONSOLA HOST LISTA",
                waitingForHost: "ESPERANDO AL HOST",
                minimumOperativesSuffix: "OPERATIVOS MINIMOS",
                readyCheck: "// CHECK DE LISTOS",
                operativeConfirmed: "OPERATIVO CONFIRMADO",
                areYouReady: "ESTAS LISTO?",
                operativesReadySuffix: "OPERATIVOS LISTOS",
                readyConfirmed: "LISTO CONFIRMADO",
                confirmReady: "CONFIRMAR LISTO",
                startGame: "INICIAR PARTIDA",
                returnToLobby: "VOLVER AL LOBBY",
                leaveRoom: "SALIR DE LA SALA",
                roulette: "// RULETA",
                selecting: "SELECCIONANDO",
                firstQuestionVector: "PRIMER VECTOR DE PREGUNTA",
                armingFinalPayload: "ARMANDO PAYLOAD FINAL",
                waitingForHostSignal: "ESPERANDO SENAL DEL HOST",
                result: "// RESULTADO",
                spyWins: "GANA EL ESPIA",
                detectivesWin: "GANAN DETECTIVES",
                wordLabel: "PALABRA",
                spyLabel: "ESPIA",
                classified: "CLASIFICADO",
                roomKey: "// CLAVE DE SALA",
                activeMetric: "ACTIVOS",
                questionsMetric: "PREGUNTAS",
                votesMetric: "VOTOS",
                hostConsole: "// CONSOLA HOST",
                missionConfig: "// CONFIG MISION",
                mode: "MODO",
                questionsMode: "PREGUNTAS",
                associationsMode: "ASOCIACIONES",
                questionsSubtitle: "Cadena de preguntas dirigida con ocho pulsos tacticos.",
                associationsSubtitle: "Gira el hablante y sigue el rastro de asociaciones.",
                duration: "DURACION",
                minuteSuffix: "MIN",
                wordSource: "FUENTE DE PALABRAS",
                builtinIntel: "INTEL INTEGRADA",
                syncingWordPacks: "SINCRONIZANDO PACKS",
                customPacksAvailableSuffix: "PACKS PROPIOS DISPONIBLES",
                wordsSuffix: "PALABRAS",
                customPackUnavailable: "PACK NO DISPONIBLE",
                operatives: "// OPERATIVOS",
                outBadge: "FUERA",
                hostBadge: "HOST",
                askBadge: "PREG",
                voteBadge: "VOTO",
                shareRoomQR: "COMPARTIR QR",
                readyCheckAction: "CHECK DE LISTOS",
                startNow: "INICIAR AHORA",
                noActiveRoom: "SIN SALA ACTIVA",
                openHome: "ABRIR INICIO",
                dealing: "REPARTO",
                voting: "VOTACION",
                results: "RESULTADOS",
                waiting: "ESPERA",
                readyVoting: "LISTOS",
                playing: "EN JUEGO",
                finished: "FINALIZADA",
                modeSynced: "MODO SINCRONIZADO",
                readyCheckSent: "CHECK DE LISTOS ENVIADO",
                lobbyRestored: "LOBBY RESTAURADO",
                roomSynced: "SALA SINCRONIZADA",
                missionTimer: "// TIMER MISION",
                timeUp: "TIEMPO AGOTADO",
                liveStatus: "LIVE",
                callFinalVote: "LLAMA VOTO FINAL",
                timerHintLive: "PREGUNTA, DESVIA, BUSCA PATRONES",
                roleCard: "// CARTA DE ROL",
                tapEyeToReveal: "TOCA EL OJO PARA VER",
                cardCheck: "// CHECK DE CARTA",
                cardConfirmed: "CARTA CONFIRMADA",
                readYourRole: "LEE TU ROL",
                readyShort: "LISTO",
                waitShort: "ESPERA",
                cardTimerHint: "El timer empieza cuando todos confirman su carta.",
                waitingForTeam: "ESPERANDO EQUIPO",
                confirmCardRead: "CONFIRMAR CARTA",
                associationDrum: "// TAMBOR DE ASOCIACION",
                spinToStart: "GIRA PARA EMPEZAR",
                roundLabel: "RONDA",
                sayOneAssociation: "DI UNA ASOCIACION",
                questionVector: "// VECTOR DE PREGUNTA",
                asker: "PREGUNTA",
                answer: "RESPONDE",
                pending: "PENDIENTE",
                voteProtocol: "// PROTOCOLO DE VOTO",
                whoIsSpy: "QUIEN ES EL ESPIA?",
                questionCycleComplete: "CICLO DE PREGUNTAS COMPLETO",
                requestVoteHint: "Pide una votacion para abrir la acusacion final.",
                spectatorVoteHint: "Estas mirando. Solo operativos activos votan.",
                voteLockedPrefix: "VOTO BLOQUEADO",
                playAgainEyebrow: "// JUGAR DE NUEVO",
                teamReadyAnotherRun: "EQUIPO LISTO PARA OTRA",
                voteForNewGame: "VOTAR NUEVA PARTIDA",
                replayVoteLocked: "REPLAY BLOQUEADO",
                playAgain: "JUGAR DE NUEVO",
                backToLobby: "VOLVER AL LOBBY",
                waitingHostResetLobby: "ESPERANDO RESET DEL HOST",
                guessWord: "ADIVINAR PALABRA",
                nextAssociation: "SIGUIENTE ASOCIACION",
                nextQuestion: "SIGUIENTE PREGUNTA",
                votingOpen: "VOTACION ABIERTA",
                requestVotePrefix: "PEDIR VOTO",
                spectatorMode: "MODO ESPECTADOR",
                spectatorSubtitle: "Observa la mesa. Tu voto esta bloqueado.",
                youAreSpy: "ERES EL ESPIA",
                youAreDetective: "ERES DETECTIVE",
                categoryLabel: "Categoria",
                classicCategory: "CLASICO",
                secretWord: "PALABRA SECRETA",
                readyRemoved: "LISTO RETIRADO",
                readyLocked: "LISTO BLOQUEADO",
                rouletteArmed: "RULETA ARMADA",
                gameReady: "PARTIDA LISTA",
                associationSpun: "ASOCIACION GIRADA",
                questionSent: "PREGUNTA ENVIADA",
                cardConfirmedStatus: "CARTA CONFIRMADA",
                voteRequestedStatus: "VOTO PEDIDO",
                voteLockedStatus: "VOTO BLOQUEADO",
                spyGuessLocked: "INTENTO DEL ESPIA BLOQUEADO",
                spyGuessEyebrow: "// INTENTO DEL ESPIA",
                chooseWord: "ELIGE LA PALABRA",
                spyGuessHint: "Un acierto termina la partida para el espia. Un error entrega el archivo a detectives."
            )
        case .ru:
            GameCopy(
                eyebrow: "// КОМНАТА",
                standby: "ОЖИДАНИЕ",
                lobby: "// ЛОББИ",
                hostConsoleReady: "КОНСОЛЬ ХОСТА ГОТОВА",
                waitingForHost: "ЖДЕМ ХОСТА",
                minimumOperativesSuffix: "МИНИМУМ ОПЕРАТИВНИКА",
                readyCheck: "// ПРОВЕРКА ГОТОВНОСТИ",
                operativeConfirmed: "ОПЕРАТИВНИК ГОТОВ",
                areYouReady: "ТЫ ГОТОВ?",
                operativesReadySuffix: "ОПЕРАТИВНИКОВ ГОТОВЫ",
                readyConfirmed: "ГОТОВНОСТЬ ПОДТВЕРЖДЕНА",
                confirmReady: "ПОДТВЕРДИТЬ ГОТОВНОСТЬ",
                startGame: "НАЧАТЬ ИГРУ",
                returnToLobby: "ВЕРНУТЬСЯ В ЛОББИ",
                leaveRoom: "ПОКИНУТЬ КОМНАТУ",
                roulette: "// РУЛЕТКА",
                selecting: "ВЫБОР",
                firstQuestionVector: "ПЕРВЫЙ ВЕКТОР ВОПРОСА",
                armingFinalPayload: "ЗАРЯЖАЕМ ФИНАЛЬНЫЙ ПАКЕТ",
                waitingForHostSignal: "ЖДЕМ СИГНАЛ ХОСТА",
                result: "// РЕЗУЛЬТАТ",
                spyWins: "ШПИОН ПОБЕДИЛ",
                detectivesWin: "ДЕТЕКТИВЫ ПОБЕДИЛИ",
                wordLabel: "СЛОВО",
                spyLabel: "ШПИОН",
                classified: "ЗАСЕКРЕЧЕНО",
                roomKey: "// КОД КОМНАТЫ",
                activeMetric: "АКТИВНЫХ",
                questionsMetric: "ВОПРОСЫ",
                votesMetric: "ГОЛОСА",
                hostConsole: "// КОНСОЛЬ ХОСТА",
                missionConfig: "// НАСТРОЙКИ МИССИИ",
                mode: "РЕЖИМ",
                questionsMode: "ВОПРОСЫ",
                associationsMode: "АССОЦИАЦИИ",
                questionsSubtitle: "Цепочка точечных вопросов с восемью тактическими ходами.",
                associationsSubtitle: "Крути говорящего и следи за цепочкой ассоциаций.",
                duration: "ДЛИТЕЛЬНОСТЬ",
                minuteSuffix: "МИН",
                wordSource: "ИСТОЧНИК СЛОВ",
                builtinIntel: "ВСТРОЕННЫЙ INTEL",
                syncingWordPacks: "СИНХРОНИЗАЦИЯ ПАКОВ",
                customPacksAvailableSuffix: "СВОИХ ПАКОВ ДОСТУПНО",
                wordsSuffix: "СЛОВ",
                customPackUnavailable: "ПАК НЕДОСТУПЕН",
                operatives: "// ОПЕРАТИВНИКИ",
                outBadge: "ВЫБЫЛ",
                hostBadge: "ХОСТ",
                askBadge: "СПР",
                voteBadge: "ГОЛОС",
                shareRoomQR: "ПОДЕЛИТЬСЯ QR",
                readyCheckAction: "ПРОВЕРКА ГОТОВНОСТИ",
                startNow: "НАЧАТЬ СЕЙЧАС",
                noActiveRoom: "НЕТ АКТИВНОЙ КОМНАТЫ",
                openHome: "ОТКРЫТЬ ГЛАВНУЮ",
                dealing: "РАЗДАЧА",
                voting: "ГОЛОСОВАНИЕ",
                results: "РЕЗУЛЬТАТЫ",
                waiting: "ОЖИДАНИЕ",
                readyVoting: "ГОТОВНОСТЬ",
                playing: "В ИГРЕ",
                finished: "ЗАВЕРШЕНА",
                modeSynced: "РЕЖИМ СИНХРОНИЗИРОВАН",
                readyCheckSent: "ПРОВЕРКА ГОТОВНОСТИ ОТПРАВЛЕНА",
                lobbyRestored: "ЛОББИ ВОССТАНОВЛЕНО",
                roomSynced: "КОМНАТА СИНХРОНИЗИРОВАНА",
                missionTimer: "// ТАЙМЕР МИССИИ",
                timeUp: "ВРЕМЯ ВЫШЛО",
                liveStatus: "В ИГРЕ",
                callFinalVote: "ЗОВИ ФИНАЛЬНЫЙ ГОЛОС",
                timerHintLive: "СПРАШИВАЙ, УВОДИ, ЛОВИ ПАТТЕРНЫ",
                roleCard: "// КАРТА РОЛИ",
                tapEyeToReveal: "НАЖМИ НА ГЛАЗ",
                cardCheck: "// ПРОВЕРКА КАРТ",
                cardConfirmed: "КАРТА ПОДТВЕРЖДЕНА",
                readYourRole: "ПРОЧТИ РОЛЬ",
                readyShort: "ГОТОВ",
                waitShort: "ЖДЕМ",
                cardTimerHint: "Таймер стартует после подтверждения всех карт.",
                waitingForTeam: "ЖДЕМ КОМАНДУ",
                confirmCardRead: "ПОДТВЕРДИТЬ КАРТУ",
                associationDrum: "// БАРАБАН АССОЦИАЦИЙ",
                spinToStart: "КРУТИ ДЛЯ СТАРТА",
                roundLabel: "РАУНД",
                sayOneAssociation: "НАЗОВИ АССОЦИАЦИЮ",
                questionVector: "// ВЕКТОР ВОПРОСА",
                asker: "СПРАШИВАЕТ",
                answer: "ОТВЕЧАЕТ",
                pending: "ОЖИДАНИЕ",
                voteProtocol: "// ПРОТОКОЛ ГОЛОСА",
                whoIsSpy: "КТО ШПИОН?",
                questionCycleComplete: "ЦИКЛ ВОПРОСОВ ЗАВЕРШЕН",
                requestVoteHint: "Запроси голосование, чтобы открыть финальное обвинение.",
                spectatorVoteHint: "Ты наблюдаешь. Голосуют только активные игроки.",
                voteLockedPrefix: "ГОЛОС ЗАФИКСИРОВАН",
                playAgainEyebrow: "// СЫГРАТЬ ЕЩЕ",
                teamReadyAnotherRun: "КОМАНДА ГОТОВА К НОВОЙ ИГРЕ",
                voteForNewGame: "ГОЛОС ЗА НОВУЮ ИГРУ",
                replayVoteLocked: "ГОЛОС ЗА ПОВТОР ЗАФИКСИРОВАН",
                playAgain: "ИГРАТЬ ЕЩЕ",
                backToLobby: "НАЗАД В ЛОББИ",
                waitingHostResetLobby: "ЖДЕМ ХОСТА ДЛЯ СБРОСА",
                guessWord: "УГАДАТЬ СЛОВО",
                nextAssociation: "СЛЕДУЮЩАЯ АССОЦИАЦИЯ",
                nextQuestion: "СЛЕДУЮЩИЙ ВОПРОС",
                votingOpen: "ГОЛОСОВАНИЕ ОТКРЫТО",
                requestVotePrefix: "ЗАПРОСИТЬ ГОЛОС",
                spectatorMode: "РЕЖИМ НАБЛЮДАТЕЛЯ",
                spectatorSubtitle: "Наблюдай за столом. Голос отключен.",
                youAreSpy: "ТЫ ШПИОН",
                youAreDetective: "ТЫ ДЕТЕКТИВ",
                categoryLabel: "КАТЕГОРИЯ",
                classicCategory: "КЛАССИКА",
                secretWord: "СЕКРЕТНОЕ СЛОВО",
                readyRemoved: "ГОТОВНОСТЬ СНЯТА",
                readyLocked: "ГОТОВНОСТЬ ЗАФИКСИРОВАНА",
                rouletteArmed: "РУЛЕТКА ЗАРЯЖЕНА",
                gameReady: "ИГРА ГОТОВА",
                associationSpun: "АССОЦИАЦИЯ ВЫБРАНА",
                questionSent: "ВОПРОС ОТПРАВЛЕН",
                cardConfirmedStatus: "КАРТА ПОДТВЕРЖДЕНА",
                voteRequestedStatus: "ГОЛОС ЗАПРОШЕН",
                voteLockedStatus: "ГОЛОС ЗАФИКСИРОВАН",
                spyGuessLocked: "ДОГАДКА ШПИОНА ЗАФИКСИРОВАНА",
                spyGuessEyebrow: "// ДОГАДКА ШПИОНА",
                chooseWord: "ВЫБЕРИ СЛОВО",
                spyGuessHint: "Верная догадка завершит матч в пользу шпиона. Ошибка отдаст дело детективам."
            )
        }
    }

    func tabTitle(_ tab: AppTab) -> String {
        switch (self, tab) {
        case (.en, .home): "HOME"
        case (.en, .game): "ROOM"
        case (.en, .local): "LOCAL"
        case (.en, .leaderboard): "RANK"
        case (.en, .packs): "PACKS"
        case (.en, .history): "HIST"
        case (.en, .profile): "PROFILE"
        case (.es, .home): "INICIO"
        case (.es, .game): "SALA"
        case (.es, .local): "LOCAL"
        case (.es, .leaderboard): "RANK"
        case (.es, .packs): "PACKS"
        case (.es, .history): "HIST"
        case (.es, .profile): "PERFIL"
        case (.ru, .home): "ДОМОЙ"
        case (.ru, .game): "КОМНАТА"
        case (.ru, .local): "ЛОКАЛ"
        case (.ru, .leaderboard): "РАНГ"
        case (.ru, .packs): "КОЛОДЫ"
        case (.ru, .history): "ИСТ"
        case (.ru, .profile): "ПРОФИЛЬ"
        }
    }

    static var stored: AppLanguage {
        normalized(UserDefaults.standard.string(forKey: storageKey))
    }

    static var hasStoredPreference: Bool {
        UserDefaults.standard.string(forKey: storageKey) != nil
    }

    static func normalized(_ raw: String?) -> AppLanguage {
        guard let raw else { return .en }
        return AppLanguage(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .en
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

struct WelcomeCopy: Hashable {
    let statusPrefix: String
    let locked: String
    let tagline: String
    let enterGame: String
    let createAccount: String
    let privacy: String
    let terms: String
    let invitePrefix: String
    let inviteSuffix: String

    func inviteArmed(_ code: String) -> String {
        "\(invitePrefix) \(code) \(inviteSuffix)"
    }
}

struct AuthCopy: Hashable {
    let accessTerminal: String
    let passphraseRequired: String
    let newOperative: String
    let setPassphrase: String
    let verificationRequired: String
    let recoveryProtocol: String
    let transmissionSent: String
    let setNewPassphrase: String
    let welcomeBack: String
    let joinNetworkTitle: String
    let createPassphraseTitle: String
    let confirmIdentityTitle: String
    let resetPassphraseTitle: String
    let checkInboxTitle: String
    let newCredentialsTitle: String
    let emailSubtitle: String
    let passwordSubtitle: String
    let registerEmailSubtitle: String
    let registerPasswordSubtitle: String
    let otpSubtitlePrefix: String
    let forgotPasswordEmptySubtitle: String
    let forgotPasswordPrefix: String
    let resetEmailSentPrefix: String
    let resetPasswordSubtitle: String
    let continueAction: String
    let unlockAction: String
    let joinNetworkAction: String
    let createCredentialsAction: String
    let verifyEnterAction: String
    let dispatchResetLinkAction: String
    let confirmNewKeyAction: String
    let authenticatingBusy: String
    let recruitingBusy: String
    let verifyingBusy: String
    let dispatchingBusy: String
    let resettingBusy: String
    let passphraseLabel: String
    let confirmPassphraseLabel: String
    let newPassphraseLabel: String
    let sixDigitKeyLabel: String
    let forgotPassphrase: String
    let requestResetBody: String
    let resetInboxTitle: String
    let resetInboxDetailPrefix: String
    let resetInboxDetailSuffix: String
    let backToLogin: String
    let continueWithApple: String
    let appleSheetTitle: String
    let appleSheetBody: String
    let appleSheetDismiss: String
    let continueWithGoogle: String
    let emailDivider: String
    let requestAccessFooter: String
    let loginFooter: String
    let passphrasesMismatch: String
    let recoveryLinkNotice: String
    let passphraseUpdatedNotice: String
    let appleMissingToken: String
    let googleMissingToken: String
    let chooseNewPassphraseNotice: String
    let signInToJoinPrefix: String
    let emailPlaceholder: String

    func eyebrow(for phase: AuthPhase) -> String {
        switch phase {
        case .email:
            accessTerminal
        case .password:
            passphraseRequired
        case .registerEmail:
            newOperative
        case .registerPassword:
            setPassphrase
        case .otp:
            verificationRequired
        case .forgotPassword:
            recoveryProtocol
        case .resetEmailSent:
            transmissionSent
        case .resetPassword:
            setNewPassphrase
        }
    }

    func title(for phase: AuthPhase) -> String {
        switch phase {
        case .email, .password:
            welcomeBack
        case .registerEmail:
            joinNetworkTitle
        case .registerPassword:
            createPassphraseTitle
        case .otp:
            confirmIdentityTitle
        case .forgotPassword:
            resetPassphraseTitle
        case .resetEmailSent:
            checkInboxTitle
        case .resetPassword:
            newCredentialsTitle
        }
    }

    func subtitle(for phase: AuthPhase) -> String {
        switch phase {
        case .email:
            emailSubtitle
        case .password:
            passwordSubtitle
        case .registerEmail:
            registerEmailSubtitle
        case .registerPassword:
            registerPasswordSubtitle
        case .otp(let email):
            "\(otpSubtitlePrefix) \(email)"
        case .forgotPassword(let email):
            email.isEmpty ? forgotPasswordEmptySubtitle : "\(forgotPasswordPrefix) \(email)"
        case .resetEmailSent(let email):
            "\(resetEmailSentPrefix) \(email)"
        case .resetPassword:
            resetPasswordSubtitle
        }
    }

    func resetInboxDetail(_ email: String) -> String {
        "\(resetInboxDetailPrefix) \(email), \(resetInboxDetailSuffix)"
    }

    func signInToJoin(_ code: String?) -> String {
        "\(signInToJoinPrefix) \(code ?? "ROOM")"
    }
}

struct QRInviteCopy: Hashable {
    let roomBeaconEyebrow: String
    let roomBeaconSubtitle: String
    let transmitInvite: String
    let close: String
    let scanEyebrow: String
    let scanTitle: String
    let alignRoomBeacon: String
    let checkingCamera: String
    let cameraPreparing: String
    let cameraLocked: String
    let cameraLockedDetail: String
    let cancel: String
    let joiningPrefix: String
    let roomLinked: String
    let roomNotFound: String
    let invalidCode: String

    func joining(_ code: String) -> String {
        "\(joiningPrefix) \(code)"
    }
}

struct ProfileCopy: Hashable {
    let eyebrow: String
    let logOut: String
    let deleteDialogTitle: String
    let deleteDialogAction: String
    let cancel: String
    let deleteDialogMessage: String
    let operativeID: String
    let selectAvatar: String
    let displayName: String
    let callSignPlaceholder: String
    let saveProfile: String
    let savingProfile: String
    let archive: String
    let games: String
    let wins: String
    let rate: String
    let rating: String
    let spy: String
    let detective: String
    let leaderboard: String
    let history: String
    let languageLabel: String
    let legal: String
    let legalHint: String
    let privacy: String
    let terms: String
    let dangerZone: String
    let dangerBody: String
    let deleteAccount: String
    let deletingAccount: String
    let saved: String

}

struct HistoryCopy: Hashable {
    let eyebrow: String
    let status: String
    let title: String
    let subtitle: String
    let games: String
    let wins: String
    let rate: String
    let loading: String
    let empty: String
    let operatives: String
    let roomFallback: String
    let categoryFallback: String
    let unknownRole: String
    let spyRole: String
    let detectiveRole: String
    let win: String
    let loss: String

    func roleLabel(_ rawRole: String?) -> String {
        switch rawRole?.lowercased() {
        case "spy":
            spyRole
        case "detective":
            detectiveRole
        default:
            unknownRole
        }
    }

    func resultLabel(won: Bool) -> String {
        won ? win : loss
    }
}

struct LeaderboardCopy: Hashable {
    let eyebrow: String
    let status: String
    let title: String
    let subtitle: String
    let loading: String
    let empty: String
    let rankHeader: String
    let playerHeader: String
    let ratingHeader: String
    let winsHeader: String
    let games: String
    let winRate: String

    func detail(games count: Int, winRate rate: Int) -> String {
        "\(count) \(games) · \(rate)% \(winRate)"
    }
}

struct WordPacksCopy: Hashable {
    let eyebrow: String
    let status: String
    let title: String
    let countSuffix: String
    let loading: String
    let emptyTitle: String
    let emptyBody: String
    let createFirstPack: String
    let customFallback: String
    let wordsSuffix: String
    let removingPack: String
    let deleteDialogTitle: String
    let deleteActionPrefix: String
    let cancel: String
    let deleteMessagePrefix: String
    let deleteMessageSuffix: String
    let editor: WordPackEditorCopy

    func countLabel(_ count: Int) -> String {
        "\(count) \(countSuffix)"
    }

    func wordsLabel(_ count: Int) -> String {
        "\(count) \(wordsSuffix)"
    }

    func deleteAction(for pack: WordPack) -> String {
        "\(deleteActionPrefix) \(pack.name.uppercased())"
    }

    func deleteMessage(for pack: WordPack) -> String {
        "\(deleteMessagePrefix) \(pack.name) \(deleteMessageSuffix)"
    }
}

struct WordPackEditorCopy: Hashable {
    let eyebrow: String
    let newTitle: String
    let editTitle: String
    let wordsMetric: String
    let modeMetric: String
    let createMode: String
    let updateMode: String
    let aiGeneration: String
    let themePlaceholder: String
    let wordsToGenerate: String
    let generateWords: String
    let aiDraftHint: String
    let packNameLabel: String
    let packNamePlaceholder: String
    let categoryLabel: String
    let categoryPlaceholder: String
    let wordsLabel: String
    let wordsInputHint: String
    let emptyWordsHint: String
    let createPack: String
    let savePack: String
    let signInRequired: String
    let packNeedsNameAndWords: String
    let enterThemeFirst: String
    let aiReady: String
    let wordsUnit: String
    let of: String
    let today: String
    let previewSaved: String

    func title(isEditing: Bool) -> String {
        isEditing ? editTitle : newTitle
    }

    func mode(isEditing: Bool) -> String {
        isEditing ? updateMode : createMode
    }

    func saveAction(isEditing: Bool) -> String {
        isEditing ? savePack : createPack
    }

    func aiReadyMessage(words count: Int, used: Int?, limit: Int?) -> String {
        guard let used, let limit else {
            return "\(aiReady) / \(count) \(wordsUnit)"
        }
        return "\(aiReady) / \(count) \(wordsUnit) / \(used) \(of) \(limit) \(today)"
    }
}

struct HomeCopy: Hashable {
    let eyebrow: String
    let operativeLabel: String
    let unknownOperative: String
    let missionControl: String
    let createOnlineRoom: String
    let roomKeyPlaceholder: String
    let scanQR: String
    let localPassMode: String
    let ranked: String
    let archive: String
    let activeRoom: String
    let liveSignals: String
    let recentFiles: String
    let noArchiveEntries: String
    let openArchive: String
    let roomLabel: String
    let operatives: String
    let unknown: String
    let win: String
    let loss: String
    let spyRole: String
    let detectiveRole: String
    let roomNotFound: String
    let roomReadySuffix: String
    let waiting: String
    let readyVoting: String
    let roulette: String
    let playing: String
    let finished: String

    func roomReady(_ code: String) -> String {
        "\(roomLabel) \(code) \(roomReadySuffix)"
    }

    func statusLabel(_ rawStatus: String?) -> String {
        return switch (rawStatus ?? "waiting").lowercased() {
        case "waiting":
            waiting
        case "ready_voting":
            readyVoting
        case "roulette":
            roulette
        case "playing":
            playing
        case "finished":
            finished
        default:
            rawStatus?.uppercased() ?? waiting
        }
    }

    func roleLabel(_ rawRole: String?) -> String {
        guard let rawRole, !rawRole.isEmpty else { return unknown }
        return switch rawRole.lowercased() {
        case "spy":
            spyRole
        case "detective":
            detectiveRole
        default:
            rawRole.uppercased()
        }
    }
}

struct GameCopy: Hashable {
    let eyebrow: String
    let standby: String
    let lobby: String
    let hostConsoleReady: String
    let waitingForHost: String
    let minimumOperativesSuffix: String
    let readyCheck: String
    let operativeConfirmed: String
    let areYouReady: String
    let operativesReadySuffix: String
    let readyConfirmed: String
    let confirmReady: String
    let startGame: String
    let returnToLobby: String
    let leaveRoom: String
    let roulette: String
    let selecting: String
    let firstQuestionVector: String
    let armingFinalPayload: String
    let waitingForHostSignal: String
    let result: String
    let spyWins: String
    let detectivesWin: String
    let wordLabel: String
    let spyLabel: String
    let classified: String
    let roomKey: String
    let activeMetric: String
    let questionsMetric: String
    let votesMetric: String
    let hostConsole: String
    let missionConfig: String
    let mode: String
    let questionsMode: String
    let associationsMode: String
    let questionsSubtitle: String
    let associationsSubtitle: String
    let duration: String
    let minuteSuffix: String
    let wordSource: String
    let builtinIntel: String
    let syncingWordPacks: String
    let customPacksAvailableSuffix: String
    let wordsSuffix: String
    let customPackUnavailable: String
    let operatives: String
    let outBadge: String
    let hostBadge: String
    let askBadge: String
    let voteBadge: String
    let shareRoomQR: String
    let readyCheckAction: String
    let startNow: String
    let noActiveRoom: String
    let openHome: String
    let dealing: String
    let voting: String
    let results: String
    let waiting: String
    let readyVoting: String
    let playing: String
    let finished: String
    let modeSynced: String
    let readyCheckSent: String
    let lobbyRestored: String
    let roomSynced: String
    let missionTimer: String
    let timeUp: String
    let liveStatus: String
    let callFinalVote: String
    let timerHintLive: String
    let roleCard: String
    let tapEyeToReveal: String
    let cardCheck: String
    let cardConfirmed: String
    let readYourRole: String
    let readyShort: String
    let waitShort: String
    let cardTimerHint: String
    let waitingForTeam: String
    let confirmCardRead: String
    let associationDrum: String
    let spinToStart: String
    let roundLabel: String
    let sayOneAssociation: String
    let questionVector: String
    let asker: String
    let answer: String
    let pending: String
    let voteProtocol: String
    let whoIsSpy: String
    let questionCycleComplete: String
    let requestVoteHint: String
    let spectatorVoteHint: String
    let voteLockedPrefix: String
    let playAgainEyebrow: String
    let teamReadyAnotherRun: String
    let voteForNewGame: String
    let replayVoteLocked: String
    let playAgain: String
    let backToLobby: String
    let waitingHostResetLobby: String
    let guessWord: String
    let nextAssociation: String
    let nextQuestion: String
    let votingOpen: String
    let requestVotePrefix: String
    let spectatorMode: String
    let spectatorSubtitle: String
    let youAreSpy: String
    let youAreDetective: String
    let categoryLabel: String
    let classicCategory: String
    let secretWord: String
    let readyRemoved: String
    let readyLocked: String
    let rouletteArmed: String
    let gameReady: String
    let associationSpun: String
    let questionSent: String
    let cardConfirmedStatus: String
    let voteRequestedStatus: String
    let voteLockedStatus: String
    let spyGuessLocked: String
    let spyGuessEyebrow: String
    let chooseWord: String
    let spyGuessHint: String

    func statusLabel(_ rawStatus: String?) -> String {
        switch (rawStatus ?? "waiting").lowercased() {
        case "waiting":
            waiting
        case "ready_voting":
            readyVoting
        case "roulette":
            roulette.replacingOccurrences(of: "// ", with: "")
        case "playing":
            playing
        case "finished", "ended":
            finished
        default:
            rawStatus?.uppercased() ?? standby
        }
    }

    func minimumOperatives(_ count: Int) -> String {
        "\(count) / 3 \(minimumOperativesSuffix)"
    }

    func operativesReady(_ ready: Int, total: Int) -> String {
        "\(ready) / \(total) \(operativesReadySuffix)"
    }

    func wordResult(_ word: String?) -> String {
        "\(wordLabel): \((word?.nilIfBlank ?? classified).uppercased())"
    }

    func spyResult(_ name: String) -> String {
        "\(spyLabel): \(name.uppercased())"
    }

    func builtinSummary(words count: Int) -> String {
        "\(builtinIntel) · \(count) \(wordsSuffix)"
    }

    func selectedPackSummary(name: String, words count: Int) -> String {
        "\(name.uppercased()) · \(count) \(wordsSuffix)"
    }

    func customPacksAvailable(_ count: Int) -> String {
        "\(count) \(customPacksAvailableSuffix)"
    }

    func modeTitle(_ mode: SpyGameMode) -> String {
        switch mode {
        case .questions:
            questionsMode
        case .associations:
            associationsMode
        }
    }

    func modeSubtitle(_ mode: SpyGameMode) -> String {
        switch mode {
        case .questions:
            questionsSubtitle
        case .associations:
            associationsSubtitle
        }
    }

    func roundAssociation(_ round: Int) -> String {
        "\(roundLabel) \(round) · \(sayOneAssociation)"
    }

    func voteLocked(_ name: String) -> String {
        "\(voteLockedPrefix): \(name.uppercased())"
    }

    func requestVote(_ current: Int, threshold: Int) -> String {
        "\(requestVotePrefix) \(current)/\(threshold)"
    }

    func categorySubtitle(_ category: String?) -> String {
        "\(categoryLabel): \((category?.nilIfBlank ?? classicCategory).uppercased())"
    }
}

struct LocalGameCopy: Hashable {
    let eyebrow: String
    let setupStatus: String
    let cardsStatus: String
    let playingStatus: String
    let votingStatus: String
    let spyGuessStatus: String
    let resultsStatus: String
    let passModeTitle: String
    let localOperatives: String
    let operativeNamePlaceholder: String
    let addPlayer: String
    let dropPlayer: String
    let duration: String
    let minuteSuffix: String
    let wordPool: String
    let wordsSuffix: String
    let mode: String
    let questionsMode: String
    let classicMode: String
    let wordSource: String
    let builtinIntel: String
    let armLocalGame: String
    let passPhone: String
    let lockScreen: String
    let revealCard: String
    let beginTimer: String
    let nextPlayer: String
    let timerEyebrow: String
    let wordHidden: String
    let questionVector: String
    let asker: String
    let answer: String
    let pending: String
    let nextQuestion: String
    let callVote: String
    let finalAccusation: String
    let whoIsSpy: String
    let archive: String
    let spyWins: String
    let detectivesWin: String
    let wordLabel: String
    let spyLabel: String
    let newRound: String
    let returnSetup: String
    let needTwoOperatives: String
    let tapToReveal: String
    let youAreSpy: String
    let youAreDetective: String
    let categoryLabel: String
    let spyHint: String
    let secretWord: String
    let fallbackPlayer: String

    func sliderValue(_ value: Double, suffix: String) -> String {
        "\(Int(value)) \(suffix)"
    }

    func wordResult(_ word: String) -> String {
        "\(wordLabel): \(word.uppercased())"
    }

    func spyResult(_ name: String) -> String {
        "\(spyLabel): \(name.uppercased())"
    }

    func category(_ category: String) -> String {
        "\(categoryLabel): \(category.uppercased())"
    }
}

enum TutorialMode: String, CaseIterable, Identifiable, Hashable {
    case questions
    case associations

    var id: String { rawValue }
}

struct TutorialStep: Identifiable, Hashable {
    let icon: String
    let title: String
    let text: String

    var id: String { title }
}

enum SpyID {
    private static let namespace = "com.spyclash.spyid.v2:"

    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact: String

        if raw.count == 6 {
            compact = raw
        } else if raw.count == 7 {
            let separator = raw.index(raw.startIndex, offsetBy: 3)
            guard raw[separator] == "-" else { return nil }
            compact = raw.replacingOccurrences(of: "-", with: "")
        } else {
            return nil
        }

        guard compact.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return nil
        }
        return "\(compact.prefix(3))-\(compact.suffix(3))"
    }

    static func formatInput(_ value: String) -> String {
        let compact = value.unicodeScalars
            .filter { (48...57).contains($0.value) }
            .prefix(6)
            .map(String.init)
            .joined()

        guard compact.count > 3 else { return compact }
        return "\(compact.prefix(3))-\(compact.dropFirst(3))"
    }

    static func derive(userID: String, attempt: Int = 0) -> String {
        let normalizedAttempt = max(0, attempt)
        let source = Data("\(namespace)\(userID.trimmingCharacters(in: .whitespacesAndNewlines)):\(normalizedAttempt)".utf8)
        let digest = SHA256.hash(data: source)
        let value = digest.prefix(4).reduce(UInt32.zero) { partial, byte in
            (partial << 8) | UInt32(byte)
        } % 1_000_000
        let compact = String(format: "%06u", value)
        return "\(compact.prefix(3))-\(compact.suffix(3))"
    }
}

struct SpyUser: Codable, Identifiable, Equatable {
    let id: String
    let email: String
    let fullName: String?
    let displayName: String?
    let avatar: String?
    let language: String?
    let role: String?
    let isVerified: Bool?
    let rating: Int?
    let gamesPlayed: Int?
    let gamesWon: Int?
    let remoteSpyID: String?
    let spyCardTheme: String?
    let spyCardAccent: String?
    let spyCardBadge: String?

    var callSign: String {
        displayName?.nilIfBlank ?? fullName?.nilIfBlank ?? email.components(separatedBy: "@").first ?? "Operative"
    }

    /// The backend owns the collision-safe assignment. A matching deterministic
    /// candidate keeps pre-migration profile surfaces in the six-digit format.
    var spyID: String {
        SpyID.normalize(remoteSpyID) ?? SpyID.derive(userID: id)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case fullName = "full_name"
        case displayName = "display_name"
        case avatar
        case language
        case role
        case isVerified = "is_verified"
        case rating
        case gamesPlayed = "games_played"
        case gamesWon = "games_won"
        case remoteSpyID = "spy_id"
        case spyCardTheme = "spy_card_theme"
        case spyCardAccent = "spy_card_accent"
        case spyCardBadge = "spy_card_badge"
    }
}

enum SpyCardThemeID: String, Codable, CaseIterable, Identifiable {
    case field
    case blacksite
    case dossier

    var id: String { rawValue }
    var requiresFullAccess: Bool { self != .field }
}

enum SpyCardAccentID: String, Codable, CaseIterable, Identifiable {
    case signalRed = "signal_red"
    case clearanceAmber = "clearance_amber"
    case verifiedGreen = "verified_green"

    var id: String { rawValue }
    var requiresFullAccess: Bool { self != .signalRed }
}

enum SpyCardBadgeID: String, Codable, CaseIterable, Identifiable {
    case operative
    case ghost
    case analyst
    case handler

    var id: String { rawValue }
    var requiresFullAccess: Bool { self != .operative }
}

struct PublicSpyProfile: Codable, Identifiable, Equatable {
    let id: String
    let spyID: String
    let displayName: String
    let avatar: String
    let spyCardTheme: String
    let spyCardAccent: String
    let spyCardBadge: String
    let rating: Int
    let gamesPlayed: Int
    let gamesWon: Int
    let winRate: Int

    enum CodingKeys: String, CodingKey {
        case id
        case spyID = "spy_id"
        case displayName = "display_name"
        case avatar
        case spyCardTheme = "spy_card_theme"
        case spyCardAccent = "spy_card_accent"
        case spyCardBadge = "spy_card_badge"
        case rating
        case gamesPlayed = "games_played"
        case gamesWon = "games_won"
        case winRate = "win_rate"
    }
}

struct CommunityRelationship: Codable, Identifiable, Equatable {
    let id: String
    let status: String
    let direction: String
    let profile: PublicSpyProfile
}

struct CommunityRoomInvite: Codable, Identifiable, Equatable {
    let id: String
    let status: String
    let roomID: String
    let roomCode: String
    let createdAt: String
    let sender: PublicSpyProfile

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case roomID = "room_id"
        case roomCode = "room_code"
        case createdAt = "created_at"
        case sender
    }
}

struct CommunityState: Codable, Equatable {
    let me: PublicSpyProfile
    let friends: [CommunityRelationship]
    let incoming: [CommunityRelationship]
    let outgoing: [CommunityRelationship]
    let blocked: [CommunityRelationship]
    let incomingRoomInvites: [CommunityRoomInvite]

    enum CodingKeys: String, CodingKey {
        case me
        case friends
        case incoming
        case outgoing
        case blocked
        case incomingRoomInvites = "incoming_room_invites"
    }

    init(
        me: PublicSpyProfile,
        friends: [CommunityRelationship],
        incoming: [CommunityRelationship],
        outgoing: [CommunityRelationship],
        blocked: [CommunityRelationship] = [],
        incomingRoomInvites: [CommunityRoomInvite] = []
    ) {
        self.me = me
        self.friends = friends
        self.incoming = incoming
        self.outgoing = outgoing
        self.blocked = blocked
        self.incomingRoomInvites = incomingRoomInvites
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        me = try container.decode(PublicSpyProfile.self, forKey: .me)
        friends = try container.decodeIfPresent([CommunityRelationship].self, forKey: .friends) ?? []
        incoming = try container.decodeIfPresent([CommunityRelationship].self, forKey: .incoming) ?? []
        outgoing = try container.decodeIfPresent([CommunityRelationship].self, forKey: .outgoing) ?? []
        blocked = try container.decodeIfPresent([CommunityRelationship].self, forKey: .blocked) ?? []
        incomingRoomInvites = try container.decodeIfPresent(
            [CommunityRoomInvite].self,
            forKey: .incomingRoomInvites
        ) ?? []
    }
}

struct CommunityRelationshipSummary: Codable, Equatable {
    let id: String
    let status: String
    let direction: String
}

struct CommunitySearchResult: Codable, Equatable {
    let profile: PublicSpyProfile
    let isSelf: Bool
    let relationship: CommunityRelationshipSummary?

    enum CodingKeys: String, CodingKey {
        case profile
        case isSelf = "is_self"
        case relationship
    }
}

struct CommunityDirectoryPage: Codable, Equatable {
    let profiles: [PublicSpyProfile]
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case profiles
        case nextOffset = "next_offset"
    }
}

struct CommunityProfileComment: Codable, Identifiable, Equatable {
    let id: String
    let body: String
    let createdAt: String
    let author: PublicSpyProfile
    let canDelete: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case body
        case createdAt = "created_at"
        case author
        case canDelete = "can_delete"
    }
}

struct CommunityProfileDetail: Codable, Equatable {
    let profile: PublicSpyProfile
    let isSelf: Bool
    let relationship: CommunityRelationshipSummary?
    let friends: [PublicSpyProfile]
    let comments: [CommunityProfileComment]

    enum CodingKeys: String, CodingKey {
        case profile
        case isSelf = "is_self"
        case relationship
        case friends
        case comments
    }
}

struct CommunityActionAcknowledgement: Codable, Equatable {
    let ok: Bool
}

enum CommunityReportReason: String, Codable, CaseIterable, Identifiable {
    case harassment
    case hateSpeech = "hate_speech"
    case sexualContent = "sexual_content"
    case violenceOrThreats = "violence_or_threats"
    case spam
    case impersonation
    case other

    var id: String { rawValue }
}

struct CommunityInviteActionResult: Codable, Equatable {
    let state: CommunityState
    let roomCode: String?

    enum CodingKeys: String, CodingKey {
        case state
        case roomCode = "room_code"
    }
}

struct LoginResponse: Codable {
    let accessToken: String
    let user: SpyUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case user
    }
}

struct VerifyResponse: Codable {
    let accessToken: String?
    let user: SpyUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case user
    }
}

struct Player: Codable, Hashable, Identifiable {
    var id: String { email }
    let email: String
    var name: String
    var avatar: String
}

struct VoteRecord: Codable, Hashable, Identifiable {
    var id: String { voterEmail }
    let voterEmail: String
    let votedForEmail: String

    enum CodingKeys: String, CodingKey {
        case voterEmail = "voter_email"
        case votedForEmail = "voted_for_email"
    }
}

enum SpyGameMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case questions
    case associations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .questions: "QUESTIONS"
        case .associations: "ASSOCIATIONS"
        }
    }

    var subtitle: String {
        switch self {
        case .questions: "Directed question chain with eight tactical prompts."
        case .associations: "Spin the speaker and follow the association trail."
        }
    }
}

struct WordPoolEntry: Codable, Hashable, Identifiable {
    var id: String { word }
    var word: String
    var enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case word
        case enabled
    }

    init(word: String, enabled: Bool? = true) {
        self.word = word
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let rawWord = try? single.decode(String.self) {
            word = rawWord
            enabled = true
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decode(String.self, forKey: .word)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    }
}

struct PlayerFeedback: Codable, Hashable {
    let email: String
    let likes: Int
    let dislikes: Int
}

struct GameRoom: Codable, Identifiable, Hashable {
    let id: String
    var code: String
    var hostEmail: String?
    var matchID: String?
    var status: String?
    var players: [Player]?
    var spyEmail: String?
    var secretWord: String?
    var word: String?
    var category: String?
    var roundNumber: Int?
    var questionsInRound: Int?
    var currentAskerEmail: String?
    var currentAnswererEmail: String?
    var winner: String?
    var introStartedAt: String?
    var gameStartedAt: String?
    var gameDurationSeconds: Int?
    var gamePausedAt: String?
    var gamePausedTotalSeconds: Int?
    var questionPhase: String?
    var currentAnswer: String?
    var currentAnswerFeedback: String?
    var gameMode: String?
    var wordPool: [WordPoolEntry]?
    var rouletteTargetEmail: String?
    var spyGuess: String?
    var eliminatedEmails: [String]?
    var playerFeedback: [PlayerFeedback]?
    var cardsRead: [String]?
    var readyPlayers: [String]?
    var spectators: [String]?
    var voteRequests: [String]?
    var detectiveVotes: [VoteRecord]?

    var normalizedStatus: String {
        (status ?? "waiting").lowercased()
    }

    var displayWord: String? {
        secretWord?.nilIfBlank ?? word?.nilIfBlank
    }

    var playersList: [Player] {
        players ?? []
    }

    var gameModeValue: SpyGameMode {
        SpyGameMode(rawValue: (gameMode ?? "").lowercased()) ?? .questions
    }

    var wordPoolList: [WordPoolEntry] {
        wordPool ?? []
    }

    var enabledWordPool: [WordPoolEntry] {
        wordPoolList.filter { $0.enabled ?? true }
    }

    var spectatorsList: [String] {
        spectators ?? []
    }

    var activePlayers: [Player] {
        playersList.filter { !spectatorsList.contains($0.email) }
    }

    var voteRequestsList: [String] {
        voteRequests ?? []
    }

    var activeVoteRequests: [String] {
        voteRequestsList.filter { email in
            activePlayers.contains { $0.email == email }
        }
    }

    var voteThreshold: Int {
        let count = activePlayers.count
        guard count > 0 else { return 0 }
        return Int(ceil(Double(count) * 0.51))
    }

    var isVotingActive: Bool {
        voteThreshold > 0 && activeVoteRequests.count >= voteThreshold
    }

    var detectiveVotesList: [VoteRecord] {
        detectiveVotes ?? []
    }

    var cardsReadList: [String] {
        cardsRead ?? []
    }

    var allRoleCardsRead: Bool {
        !playersList.isEmpty && playersList.allSatisfy { cardsReadList.contains($0.email) }
    }

    var isGamePaused: Bool {
        gamePausedAt?.nilIfBlank != nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case hostEmail = "host_email"
        case matchID = "match_id"
        case status
        case players
        case spyEmail = "spy_email"
        case secretWord = "secret_word"
        case word
        case category
        case roundNumber = "round_number"
        case questionsInRound = "questions_in_round"
        case currentAskerEmail = "current_asker_email"
        case currentAnswererEmail = "current_answerer_email"
        case winner
        case introStartedAt = "intro_started_at"
        case gameStartedAt = "game_started_at"
        case gameDurationSeconds = "game_duration_seconds"
        case gamePausedAt = "game_paused_at"
        case gamePausedTotalSeconds = "game_paused_total_seconds"
        case questionPhase = "question_phase"
        case currentAnswer = "current_answer"
        case currentAnswerFeedback = "current_answer_feedback"
        case gameMode = "game_mode"
        case wordPool = "word_pool"
        case rouletteTargetEmail = "roulette_target_email"
        case spyGuess = "spy_guess"
        case eliminatedEmails = "eliminated_emails"
        case playerFeedback = "player_feedback"
        case cardsRead = "cards_read"
        case readyPlayers = "ready_players"
        case spectators
        case voteRequests = "vote_requests"
        case detectiveVotes = "detective_votes"
    }
}

extension GameRoom {
    static func previewRoom(status rawStatus: String = "waiting", playerCount: Int = 3) -> GameRoom {
        let basePlayers = [
            Player(email: "operative.preview@spyclash.local", name: "Red Raven", avatar: "🕵️"),
            Player(email: "cipher@spyclash.local", name: "Cipher", avatar: "🎭"),
            Player(email: "ghost@spyclash.local", name: "Ghost", avatar: "👤")
        ]
        let clampedPlayerCount = min(max(playerCount, basePlayers.count), 12)
        let additionalPlayers: [Player]
        if clampedPlayerCount > basePlayers.count {
            additionalPlayers = (basePlayers.count..<clampedPlayerCount).map { index in
                let number = index + 1
                return Player(
                    email: "operative\(number)@spyclash.local",
                    name: "Operative \(number)",
                    avatar: "🕶️"
                )
            }
        } else {
            additionalPlayers = []
        }
        let players = basePlayers + additionalPlayers
        let normalizedStatus = rawStatus.lowercased()
        let status: String
        let readyPlayers: [String]
        let cardsRead: [String]
        let voteRequests: [String]
        let detectiveVotes: [VoteRecord]?
        let winner: String?
        let spyEmail: String
        let questionPhase: String?

        switch normalizedStatus {
        case "ready", "ready_voting":
            status = "ready_voting"
            readyPlayers = [players[0].email, players[1].email]
            cardsRead = []
            voteRequests = []
            detectiveVotes = nil
            winner = nil
            spyEmail = players[1].email
            questionPhase = nil
        case "roulette":
            status = "roulette"
            readyPlayers = []
            cardsRead = []
            voteRequests = []
            detectiveVotes = nil
            winner = nil
            spyEmail = players[1].email
            questionPhase = nil
        case "cards", "card", "dealing":
            status = "playing"
            readyPlayers = []
            cardsRead = [players[1].email]
            voteRequests = []
            detectiveVotes = nil
            winner = nil
            spyEmail = players[1].email
            questionPhase = "asking"
        case "cards_last", "cards-last", "last-card":
            status = "playing"
            readyPlayers = []
            cardsRead = [players[1].email, players[2].email]
            voteRequests = []
            detectiveVotes = nil
            winner = nil
            spyEmail = players[1].email
            questionPhase = "asking"
        case "playing", "paused":
            status = "playing"
            readyPlayers = []
            cardsRead = players.map(\.email)
            voteRequests = []
            detectiveVotes = nil
            winner = nil
            spyEmail = players[1].email
            questionPhase = "asking"
        case "voting", "vote":
            status = "playing"
            readyPlayers = []
            cardsRead = players.map(\.email)
            voteRequests = Array(players.prefix(max(2, players.count / 2 + 1))).map(\.email)
            detectiveVotes = nil
            winner = nil
            spyEmail = players[1].email
            questionPhase = "results"
        case "spy", "spy_playing":
            status = "playing"
            readyPlayers = []
            cardsRead = players.map(\.email)
            voteRequests = []
            detectiveVotes = nil
            winner = nil
            spyEmail = players[0].email
            questionPhase = "asking"
        case "finished", "ended", "result":
            status = "finished"
            readyPlayers = [players[0].email, players[1].email]
            cardsRead = players.map(\.email)
            voteRequests = []
            detectiveVotes = [
                VoteRecord(voterEmail: players[0].email, votedForEmail: players[1].email),
                VoteRecord(voterEmail: players[2].email, votedForEmail: players[1].email)
            ]
            winner = "detectives"
            spyEmail = players[1].email
            questionPhase = nil
        default:
            status = "waiting"
            readyPlayers = []
            cardsRead = []
            voteRequests = []
            detectiveVotes = nil
            winner = nil
            spyEmail = players[1].email
            questionPhase = nil
        }

        let startedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-132))

        return GameRoom(
            id: "preview-room-\(status)",
            code: "R7VN",
            hostEmail: players[0].email,
            matchID: ["playing", "finished"].contains(status) ? "preview-match-\(status)" : nil,
            status: status,
            players: players,
            spyEmail: spyEmail,
            secretWord: "Briefcase",
            word: "Briefcase",
            category: "Black Ops",
            roundNumber: 2,
            questionsInRound: status == "playing" ? 3 : 0,
            currentAskerEmail: players[0].email,
            currentAnswererEmail: players[2].email,
            winner: winner,
            introStartedAt: status == "roulette" ? ISO8601DateFormatter().string(from: Date()) : nil,
            gameStartedAt: status == "playing" && cardsRead.count == players.count ? startedAt : nil,
            gameDurationSeconds: 900,
            gamePausedAt: normalizedStatus == "paused" ? ISO8601DateFormatter().string(from: Date()) : nil,
            gamePausedTotalSeconds: 0,
            questionPhase: questionPhase,
            currentAnswer: nil,
            currentAnswerFeedback: nil,
            gameMode: "questions",
            wordPool: [
                WordPoolEntry(word: "Embassy"),
                WordPoolEntry(word: "Briefcase"),
                WordPoolEntry(word: "Cipher"),
                WordPoolEntry(word: "Rooftop"),
                WordPoolEntry(word: "Checkpoint")
            ],
            rouletteTargetEmail: players[0].email,
            spyGuess: nil,
            eliminatedEmails: [],
            playerFeedback: nil,
            cardsRead: cardsRead,
            readyPlayers: readyPlayers,
            spectators: [],
            voteRequests: voteRequests,
            detectiveVotes: detectiveVotes
        )
    }
}

struct WordPack: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var category: String?
    var words: [String]?
    var ownerEmail: String?
    var isPublic: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case words
        case ownerEmail = "owner_email"
        case isPublic = "is_public"
    }
}

struct GeneratedWordPack: Codable, Hashable {
    var name: String?
    var category: String
    var words: [String]
    var aiLimit: Int?
    var aiGenerationsToday: Int?
    var aiRemaining: Int? = nil

    enum CodingKeys: String, CodingKey {
        case name
        case category
        case words
        case aiLimit = "ai_limit"
        case aiGenerationsToday = "ai_generations_today"
        case aiRemaining = "ai_remaining"
    }
}

extension WordPack {
    static let previewPacks: [WordPack] = [
        WordPack(
            id: "preview-pack-places",
            name: "Night City",
            category: "Places",
            words: ["Embassy", "Harbor", "Casino", "Subway", "Museum", "Rooftop", "Theater", "Market", "Hotel", "Airport", "Vault", "Tunnel"],
            ownerEmail: "operative.preview@spyclash.local",
            isPublic: false
        ),
        WordPack(
            id: "preview-pack-tech",
            name: "Tech Signals",
            category: "Technology",
            words: ["Satellite", "Cipher", "Drone", "Firewall", "Server", "Beacon", "Console", "Sensor", "Router", "Terminal", "Proxy", "Keycard"],
            ownerEmail: "operative.preview@spyclash.local",
            isPublic: false
        ),
        WordPack(
            id: "preview-pack-party",
            name: "Party Chaos",
            category: "Social",
            words: ["Karaoke", "Pizza", "Costume", "Balcony", "Playlist", "Confetti", "Selfie", "Dancefloor", "Mocktail", "Invitation"],
            ownerEmail: "operative.preview@spyclash.local",
            isPublic: false
        )
    ]
}

struct GameHistory: Codable, Identifiable, Hashable {
    let id: String
    var playerEmail: String?
    var roomCode: String?
    var won: Bool?
    var role: String?
    var word: String?
    var category: String?
    var winner: String?
    var playerCount: Int?
    var createdDate: String?
    var matchType: String? = nil
    var ranked: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case playerEmail = "player_email"
        case roomCode = "room_code"
        case won
        case role
        case word
        case category
        case winner
        case playerCount = "player_count"
        case createdDate = "created_date"
        case matchType = "match_type"
        case ranked
    }

    var isOnlineCompetitiveMatch: Bool {
        let normalizedType = matchType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if !normalizedType.isEmpty {
            return normalizedType == "online" && ranked != false
        }
        if ranked == false {
            return false
        }

        let normalizedCode = roomCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""
        return normalizedCode.count == 6
            && normalizedCode.unicodeScalars.allSatisfy {
                CharacterSet.uppercaseLetters.contains($0)
                    || CharacterSet.decimalDigits.contains($0)
            }
    }
}

struct LeaderboardEntry: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let rating: Int
    let games: Int
    let wins: Int
    let losses: Int
    let isCurrentUser: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case rating
        case games
        case wins
        case losses
        case isCurrentUser = "is_current_user"
    }

    var winRate: Int {
        guard games > 0 else { return 0 }
        return Int((Double(wins) / Double(games) * 100).rounded())
    }
}

extension GameHistory {
    static let previewArchive: [GameHistory] = [
        GameHistory(
            id: "preview-history-1",
            playerEmail: "operative.preview@spyclash.local",
            roomCode: "R4V3N",
            won: true,
            role: "detective",
            word: "Embassy",
            category: "Classic",
            winner: "detectives",
            playerCount: 7,
            createdDate: "2026-06-22T22:14:00Z"
        ),
        GameHistory(
            id: "preview-history-2",
            playerEmail: "operative.preview@spyclash.local",
            roomCode: "N1GHT",
            won: false,
            role: "spy",
            word: "Museum",
            category: "Places",
            winner: "detectives",
            playerCount: 5,
            createdDate: "2026-06-21T19:32:00Z"
        ),
        GameHistory(
            id: "preview-history-3",
            playerEmail: "operative.preview@spyclash.local",
            roomCode: "GHOST",
            won: true,
            role: "spy",
            word: "Satellite",
            category: "Tech",
            winner: "spy",
            playerCount: 8,
            createdDate: "2026-06-19T17:08:00Z"
        )
    ]

    static let previewLeaderboardPool: [GameHistory] = previewArchive + [
        GameHistory(
            id: "preview-leader-1",
            playerEmail: "cipher@spyclash.local",
            roomCode: "C1PHR",
            won: true,
            role: "spy",
            word: "Opera",
            category: "Culture",
            winner: "spy",
            playerCount: 6,
            createdDate: "2026-06-22T18:02:00Z"
        ),
        GameHistory(
            id: "preview-leader-2",
            playerEmail: "cipher@spyclash.local",
            roomCode: "VAULT",
            won: true,
            role: "detective",
            word: "Vault",
            category: "Places",
            winner: "detectives",
            playerCount: 6,
            createdDate: "2026-06-20T18:02:00Z"
        ),
        GameHistory(
            id: "preview-leader-3",
            playerEmail: "nova@spyclash.local",
            roomCode: "N0VA",
            won: false,
            role: "detective",
            word: "Harbor",
            category: "Classic",
            winner: "spy",
            playerCount: 5,
            createdDate: "2026-06-18T21:45:00Z"
        ),
        GameHistory(
            id: "preview-leader-4",
            playerEmail: "mara@spyclash.local",
            roomCode: "M4RA",
            won: true,
            role: "detective",
            word: "Casino",
            category: "Places",
            winner: "detectives",
            playerCount: 9,
            createdDate: "2026-06-17T20:10:00Z"
        ),
        GameHistory(
            id: "preview-leader-5",
            playerEmail: "mara@spyclash.local",
            roomCode: "SABLE",
            won: false,
            role: "spy",
            word: "Subway",
            category: "Urban",
            winner: "detectives",
            playerCount: 7,
            createdDate: "2026-06-16T20:10:00Z"
        )
    ]
}

enum MembershipTier: String, Codable, CaseIterable {
    case free
    case limitless
}

struct MembershipBenefits: Codable, Equatable {
    let aiGenerationsDailyLimit: Int?
    let premiumAvatars: Bool
    let fullHistory: Bool
    let advancedStatistics: Bool
    let historyLimit: Int?

    static let free = MembershipBenefits(
        aiGenerationsDailyLimit: 10,
        premiumAvatars: false,
        fullHistory: false,
        advancedStatistics: false,
        historyLimit: 5
    )

    static let fullAccess = MembershipBenefits(
        aiGenerationsDailyLimit: nil,
        premiumAvatars: true,
        fullHistory: true,
        advancedStatistics: true,
        historyLimit: nil
    )

    enum CodingKeys: String, CodingKey {
        case aiGenerationsDailyLimit = "ai_generations_daily_limit"
        case premiumAvatars = "premium_avatars"
        case fullHistory = "full_history"
        case advancedStatistics = "advanced_statistics"
        case historyLimit = "history_limit"
    }
}

struct Membership: Equatable {
    let tier: MembershipTier
    let status: String
    let providers: [String]
    let benefits: MembershipBenefits
    let expiresAt: Date?
    let aiGenerationsToday: Int?
    let aiRemaining: Int?

    var grantsFullAccess: Bool {
        guard tier == .limitless else { return false }
        if providers.contains("casada") { return true }
        if providers.contains("preview") { return true }
        if providers.contains("admin"), expiresAt == nil { return true }
        guard let expiresAt else { return false }
        return expiresAt > Date()
    }

    init(subscriptionStatus: SubscriptionStatus) {
        // `active` remains the authority while older deployments roll forward.
        // A contradictory inactive response must never grant full access.
        let effectiveTier: MembershipTier = subscriptionStatus.active && subscriptionStatus.tier == .limitless
            ? .limitless
            : .free
        tier = effectiveTier
        status = subscriptionStatus.status
        providers = subscriptionStatus.providers
        benefits = effectiveTier == .limitless
            ? subscriptionStatus.benefits
            : .free
        expiresAt = subscriptionStatus.expiresAt
        aiGenerationsToday = subscriptionStatus.aiGenerationsToday
        aiRemaining = subscriptionStatus.aiRemaining
    }

    static let free = Membership(
        tier: .free,
        status: "free",
        providers: [],
        benefits: .free,
        expiresAt: nil,
        aiGenerationsToday: nil,
        aiRemaining: nil
    )

    static let fullAccessPreview = Membership(
        tier: .limitless,
        status: "active",
        providers: ["preview"],
        benefits: .fullAccess,
        expiresAt: nil,
        aiGenerationsToday: nil,
        aiRemaining: nil
    )

    private init(
        tier: MembershipTier,
        status: String,
        providers: [String],
        benefits: MembershipBenefits,
        expiresAt: Date?,
        aiGenerationsToday: Int?,
        aiRemaining: Int?
    ) {
        self.tier = tier
        self.status = status
        self.providers = providers
        self.benefits = benefits
        self.expiresAt = expiresAt
        self.aiGenerationsToday = aiGenerationsToday
        self.aiRemaining = aiRemaining
    }

    func updatingAIUsage(used: Int?, remaining: Int?) -> Membership {
        Membership(
            tier: tier,
            status: status,
            providers: providers,
            benefits: benefits,
            expiresAt: expiresAt,
            aiGenerationsToday: used,
            aiRemaining: remaining
        )
    }
}

struct SubscriptionStatus: Decodable {
    let active: Bool
    let tier: MembershipTier
    let status: String
    let providers: [String]
    let benefits: MembershipBenefits
    let expiresAt: Date?
    let aiGenerationsToday: Int?
    let aiRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case active
        case tier
        case status
        case providers
        case benefits
        case expiresAt = "expires_at"
        case aiGenerationsToday = "ai_generations_today"
        case aiRemaining = "ai_remaining"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedActive = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        let tierKeyIsPresent = container.contains(.tier)
        let decodedTierKey = try? container.decode(String.self, forKey: .tier)
        let decodedTier = decodedTierKey.flatMap { rawValue -> MembershipTier? in
            let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "casada" {
                // CASADA is the public full-access protocol. Internally it maps
                // to the legacy full-benefits tier to preserve wire compatibility.
                return .limitless
            }
            return MembershipTier(rawValue: normalized)
        }
        // `active` is a compatibility bridge only for the old response shape
        // where `tier` did not exist. A present-but-invalid tier must fail
        // closed instead of silently becoming full access.
        let resolvedTier = decodedTier
            ?? (!tierKeyIsPresent && decodedActive ? .limitless : .free)
        let defaults: MembershipBenefits = resolvedTier == .limitless ? .fullAccess : .free
        let partialBenefits = try container.decodeIfPresent(PartialMembershipBenefits.self, forKey: .benefits)

        active = decodedActive
        tier = resolvedTier
        status = try container.decodeIfPresent(String.self, forKey: .status)
            ?? (decodedActive ? "active" : "free")
        providers = try container.decodeIfPresent([String].self, forKey: .providers) ?? []
        benefits = MembershipBenefits(
            aiGenerationsDailyLimit: partialBenefits?.aiGenerationsDailyLimit
                ?? defaults.aiGenerationsDailyLimit,
            premiumAvatars: partialBenefits?.premiumAvatars
                ?? defaults.premiumAvatars,
            fullHistory: partialBenefits?.fullHistory
                ?? defaults.fullHistory,
            advancedStatistics: partialBenefits?.advancedStatistics
                ?? defaults.advancedStatistics,
            historyLimit: partialBenefits?.historyLimit
                ?? defaults.historyLimit
        )
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        aiGenerationsToday = try container.decodeIfPresent(Int.self, forKey: .aiGenerationsToday)
        aiRemaining = try container.decodeIfPresent(Int.self, forKey: .aiRemaining)
    }
}

private struct PartialMembershipBenefits: Decodable {
    let aiGenerationsDailyLimit: Int?
    let premiumAvatars: Bool?
    let fullHistory: Bool?
    let advancedStatistics: Bool?
    let historyLimit: Int?

    enum CodingKeys: String, CodingKey {
        case aiGenerationsDailyLimit = "ai_generations_daily_limit"
        case premiumAvatars = "premium_avatars"
        case fullHistory = "full_history"
        case advancedStatistics = "advanced_statistics"
        case historyLimit = "history_limit"
    }
}

struct EmptyResponse: Codable {}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
