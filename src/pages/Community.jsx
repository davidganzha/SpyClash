import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { motion } from "framer-motion";
import {
  Check,
  Clock3,
  DoorOpen,
  RefreshCw,
  Search,
  Send,
  UserPlus,
  X,
} from "lucide-react";
import PageChrome from "@/components/PageChrome";
import { useLanguage } from "@/components/LanguageContext";
import { useAuth } from "@/lib/AuthContext";
import { useCommunity } from "@/lib/CommunityContext";
import {
  clearRoomInviteCleanup,
  inviteCommunityOperative,
  rememberRoomInviteCleanup,
  searchCommunity,
  sendFriendRequest,
  updateFriendRequest,
  updateRoomInvite,
} from "@/lib/communityActions";
import {
  joinCommunityRoomInvite,
  relationshipForProfile,
  stateWithoutRoomInvite,
} from "@/lib/communityProtocol";
import {
  getActiveGameRoom,
  joinGameRoom,
} from "@/lib/gameRoomActions";
import { accountAvatarForDisplay } from "@/lib/avatars";
import { createPageUrl } from "@/utils";

const COPY = {
  en: {
    eyebrow: "// COMMUNITY",
    online: "OPERATIVE NETWORK",
    title: "FIND YOUR NEXT OPERATIVE",
    subtitle: "Search by callsign or SPYID. Every card is the operative's real public identity.",
    search: "CALLSIGN OR 000-000",
    refresh: "REFRESH",
    retry: "RETRY NETWORK",
    loading: "SCANNING NETWORK",
    unavailable: "OPERATIVE NETWORK TEMPORARILY UNAVAILABLE",
    roomInvites: "ROOM INVITES",
    friendRequests: "FRIEND REQUESTS",
    friends: "MY OPERATIVES",
    outgoing: "OUTGOING REQUESTS",
    directory: "PUBLIC DIRECTORY",
    noResults: "NO OPERATIVES FOUND",
    noFriends: "NO CONNECTED OPERATIVES YET",
    activeRoom: "ACTIVE INVITE CHANNEL",
    noRoom: "Create or join a waiting room to invite friends.",
    room: "ROOM",
    join: "JOIN",
    joining: "JOINING...",
    accepting: "ACCEPTING...",
    ready: "ROOM READY",
    decline: "DECLINE",
    declining: "DECLINING...",
    declined: "DECLINED",
    accept: "ACCEPT",
    accepted: "ACCEPTED",
    add: "ADD OPERATIVE",
    sending: "SENDING...",
    sent: "REQUEST SENT",
    cancel: "CANCEL",
    cancelling: "CANCELLING...",
    cancelled: "CANCELLED",
    friend: "CONNECTED",
    invite: "INVITE",
    inviting: "INVITING...",
    invited: "INVITE SENT",
    you: "YOU",
    rating: "RATING",
    games: "GAMES",
    wins: "WINS",
    actionFailed: "ACTION FAILED",
  },
  ru: {
    eyebrow: "// СООБЩЕСТВО",
    online: "СЕТЬ ОПЕРАТИВНИКОВ",
    title: "НАЙДИ СВОЕГО ОПЕРАТИВНИКА",
    subtitle: "Ищи по позывному или SPYID. Каждая карточка — настоящая публичная личность оперативника.",
    search: "ПОЗЫВНОЙ ИЛИ 000-000",
    refresh: "ОБНОВИТЬ",
    retry: "ПОВТОРИТЬ",
    loading: "СКАНИРОВАНИЕ СЕТИ",
    unavailable: "СЕТЬ ОПЕРАТИВНИКОВ ВРЕМЕННО НЕДОСТУПНА",
    roomInvites: "ПРИГЛАШЕНИЯ В КОМНАТУ",
    friendRequests: "ЗАПРОСЫ В ДРУЗЬЯ",
    friends: "МОИ ОПЕРАТИВНИКИ",
    outgoing: "ИСХОДЯЩИЕ ЗАПРОСЫ",
    directory: "ПУБЛИЧНЫЙ КАТАЛОГ",
    noResults: "ОПЕРАТИВНИКИ НЕ НАЙДЕНЫ",
    noFriends: "ПОКА НЕТ ПОДКЛЮЧЕННЫХ ОПЕРАТИВНИКОВ",
    activeRoom: "АКТИВНЫЙ КАНАЛ ПРИГЛАШЕНИЙ",
    noRoom: "Создай или открой комнату ожидания, чтобы приглашать друзей.",
    room: "КОМНАТА",
    join: "ВОЙТИ",
    joining: "ВХОДИМ...",
    accepting: "ПРИНИМАЕМ...",
    ready: "КОМНАТА ГОТОВА",
    decline: "ОТКЛОНИТЬ",
    declining: "ОТКЛОНЯЕМ...",
    declined: "ОТКЛОНЕНО",
    accept: "ПРИНЯТЬ",
    accepted: "ПРИНЯТО",
    add: "ДОБАВИТЬ",
    sending: "ОТПРАВЛЯЕМ...",
    sent: "ЗАПРОС ОТПРАВЛЕН",
    cancel: "ОТМЕНИТЬ",
    cancelling: "ОТМЕНЯЕМ...",
    cancelled: "ОТМЕНЕНО",
    friend: "В ДРУЗЬЯХ",
    invite: "ПРИГЛАСИТЬ",
    inviting: "ПРИГЛАШАЕМ...",
    invited: "ПРИГЛАШЕНИЕ ОТПРАВЛЕНО",
    you: "ЭТО ВЫ",
    rating: "РЕЙТИНГ",
    games: "ИГРЫ",
    wins: "ПОБЕДЫ",
    actionFailed: "ОШИБКА ДЕЙСТВИЯ",
  },
  uk: {
    eyebrow: "// СПІЛЬНОТА",
    online: "МЕРЕЖА ОПЕРАТИВНИКІВ",
    title: "ЗНАЙДІТЬ НАСТУПНОГО ОПЕРАТИВНИКА",
    subtitle: "Шукайте за позивним або SPYID. Кожна картка — справжня публічна особа оперативника.",
    search: "ПОЗИВНИЙ АБО 000-000",
    refresh: "ОНОВИТИ",
    retry: "ПОВТОРИТИ",
    loading: "СКАНУВАННЯ МЕРЕЖІ",
    unavailable: "МЕРЕЖА ОПЕРАТИВНИКІВ ТИМЧАСОВО НЕДОСТУПНА",
    roomInvites: "ЗАПРОШЕННЯ ДО КІМНАТИ",
    friendRequests: "ЗАПИТИ В ДРУЗІ",
    friends: "МОЇ ОПЕРАТИВНИКИ",
    outgoing: "НАДІСЛАНІ ЗАПИТИ",
    directory: "ПУБЛІЧНИЙ КАТАЛОГ",
    noResults: "ОПЕРАТИВНИКІВ НЕ ЗНАЙДЕНО",
    noFriends: "ПІДКЛЮЧЕНИХ ОПЕРАТИВНИКІВ ЩЕ НЕМАЄ",
    activeRoom: "АКТИВНИЙ КАНАЛ ЗАПРОШЕНЬ",
    noRoom: "Створіть кімнату очікування або приєднайтеся до неї, щоб запрошувати друзів.",
    room: "КІМНАТА",
    join: "УВІЙТИ",
    joining: "ВХІД...",
    accepting: "ПРИЙМАЄМО...",
    ready: "КІМНАТА ГОТОВА",
    decline: "ВІДХИЛИТИ",
    declining: "ВІДХИЛЯЄМО...",
    declined: "ВІДХИЛЕНО",
    accept: "ПРИЙНЯТИ",
    accepted: "ПРИЙНЯТО",
    add: "ДОДАТИ ОПЕРАТИВНИКА",
    sending: "НАДСИЛАЄМО...",
    sent: "ЗАПИТ НАДІСЛАНО",
    cancel: "СКАСУВАТИ",
    cancelling: "СКАСОВУЄМО...",
    cancelled: "СКАСОВАНО",
    friend: "У ДРУЗЯХ",
    invite: "ЗАПРОСИТИ",
    inviting: "ЗАПРОШУЄМО...",
    invited: "ЗАПРОШЕННЯ НАДІСЛАНО",
    you: "ЦЕ ВИ",
    rating: "РЕЙТИНГ",
    games: "ІГРИ",
    wins: "ПЕРЕМОГИ",
    actionFailed: "ПОМИЛКА ДІЇ",
  },
};

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function Section({ title, count, accent = "#e53535", children }) {
  return (
    <section className="community-section">
      <span className="community-accent-line" style={{ background: accent }} aria-hidden />
      <div className="community-section-head">
        <span>{title}</span>
        <strong style={{ color: accent }}>{count}</strong>
      </div>
      <div className="community-section-body">{children}</div>
    </section>
  );
}

function Identity({ profile, copy }) {
  return (
    <div className="community-identity">
      <div className="community-avatar" aria-hidden>{profile?.avatar || "🕵️"}</div>
      <div className="community-identity-copy">
        <strong>{String(profile?.display_name || "OPERATIVE").toUpperCase()}</strong>
        <span>{profile?.spy_id || "000-000"}</span>
      </div>
      <div className="community-stats" aria-label={`${copy.rating} ${profile?.rating || 0}`}>
        <span>{copy.rating}</span>
        <strong>{profile?.rating || 0}</strong>
      </div>
    </div>
  );
}

function ActionButton({
  actionId,
  feedback,
  label,
  icon: Icon,
  variant = "outline",
  disabled = false,
  onClick,
}) {
  const isCurrent = feedback?.id === actionId;
  const isBusy = feedback?.phase === "waiting";
  const shownLabel = isCurrent ? feedback.label : label;
  const color = isCurrent && feedback.phase === "success" ? "#59c878" : undefined;

  return (
    <motion.button
      whileTap={disabled || isBusy ? undefined : { scale: 0.97 }}
      className={variant === "primary" ? "btn-red" : "btn-outline"}
      disabled={disabled || (isBusy && !isCurrent)}
      onClick={onClick}
      style={{
        minHeight: 42,
        padding: "9px 13px",
        fontSize: 10,
        letterSpacing: 1.3,
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        gap: 7,
        color,
        borderColor: color,
        flex: 1,
      }}
    >
      {isCurrent && feedback.phase === "success" ? <Check size={14} /> : <Icon size={14} />}
      {shownLabel}
    </motion.button>
  );
}

export default function Community() {
  const { lang } = useLanguage();
  const copy = COPY[lang] || COPY.en;
  const { user } = useAuth();
  const {
    state,
    setState,
    isLoading,
    error: networkError,
    refresh,
  } = useCommunity();
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [directory, setDirectory] = useState([]);
  const [directoryLoading, setDirectoryLoading] = useState(true);
  const [directoryError, setDirectoryError] = useState(null);
  const [activeRoom, setActiveRoom] = useState(null);
  const [feedback, setFeedback] = useState(null);
  const [message, setMessage] = useState("");
  const [invitedProfileIds, setInvitedProfileIds] = useState(() => new Set());

  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      setDirectoryLoading(true);
      setDirectoryError(null);
      searchCommunity(query, { signal: controller.signal })
        .then((page) => setDirectory(Array.isArray(page?.profiles) ? page.profiles : []))
        .catch((nextError) => {
          if (nextError?.name !== "AbortError") setDirectoryError(nextError);
        })
        .finally(() => {
          if (!controller.signal.aborted) setDirectoryLoading(false);
        });
    }, query ? 300 : 0);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [query]);

  useEffect(() => {
    let cancelled = false;
    const preferredRoomId = localStorage.getItem("spy_active_room_id");
    getActiveGameRoom(preferredRoomId)
      .then((room) => {
        if (cancelled) return;
        setActiveRoom(room?.status === "waiting" ? room : null);
      })
      .catch(() => {
        if (!cancelled) setActiveRoom(null);
      });
    return () => { cancelled = true; };
  }, [user?.id]);

  const busy = feedback?.phase === "waiting";
  const relationships = useMemo(() => ({
    incoming: state?.incoming || [],
    outgoing: state?.outgoing || [],
    friends: state?.friends || [],
    roomInvites: state?.incoming_room_invites || [],
  }), [state]);

  const showFailure = async (actionId, error) => {
    setMessage(error?.message || copy.actionFailed);
    setFeedback({ id: actionId, phase: "failure", label: copy.actionFailed });
    await wait(900);
    setFeedback(null);
  };

  const runMutation = async ({ actionId, waiting, success, operation, apply }) => {
    if (busy) return null;
    setMessage("");
    setFeedback({ id: actionId, phase: "waiting", label: waiting });
    try {
      const result = await operation();
      setFeedback({ id: actionId, phase: "success", label: success });
      await wait(520);
      apply?.(result);
      setFeedback(null);
      return result;
    } catch (error) {
      await showFailure(actionId, error);
      return null;
    }
  };

  const handleFriendDecision = (record, action) => runMutation({
    actionId: `friend-${action}-${record.id}`,
    waiting: action === "accept" ? copy.accepting : copy.declining,
    success: action === "accept" ? copy.accepted : copy.declined,
    operation: () => updateFriendRequest(action, record.id),
    apply: setState,
  });

  const handleSendRequest = (profile) => runMutation({
    actionId: `friend-send-${profile.id}`,
    waiting: copy.sending,
    success: copy.sent,
    operation: () => sendFriendRequest(profile.id),
    apply: setState,
  });

  const handleCancelRequest = (record) => runMutation({
    actionId: `friend-cancel-${record.id}`,
    waiting: copy.cancelling,
    success: copy.cancelled,
    operation: () => updateFriendRequest("cancel_request", record.id),
    apply: setState,
  });

  const handleInvite = (profile) => runMutation({
    actionId: `room-send-${profile.id}`,
    waiting: copy.inviting,
    success: copy.invited,
    operation: () => inviteCommunityOperative(profile.id, activeRoom),
    apply: () => {
      setInvitedProfileIds((current) => new Set([...current, profile.id]));
    },
  });

  const handleDeclineRoomInvite = (invite) => runMutation({
    actionId: `room-decline-${invite.id}`,
    waiting: copy.declining,
    success: copy.declined,
    operation: () => updateRoomInvite("decline_room_invite", invite.id),
    apply: (result) => setState(result?.state || stateWithoutRoomInvite(state, invite.id)),
  });

  const handleJoinRoomInvite = async (invite) => {
    if (busy) return;
    const actionId = `room-accept-${invite.id}`;
    let acceptedState = null;
    setMessage("");
    setFeedback({
      id: actionId,
      phase: "waiting",
      label: invite.status === "accepted" ? copy.joining : copy.accepting,
    });

    try {
      const displayName = user?.display_name || user?.full_name || user?.email?.split("@")[0] || "OPERATIVE";
      const player = {
        name: displayName,
        avatar: accountAvatarForDisplay(user?.avatar),
      };
      const result = await joinCommunityRoomInvite({
        invite,
        player,
        acceptInvite: async (inviteId) => {
          const accepted = await updateRoomInvite("accept_room_invite", inviteId);
          acceptedState = accepted?.state || null;
          setFeedback({ id: actionId, phase: "waiting", label: copy.joining });
          return accepted;
        },
        joinRoom: joinGameRoom,
        rememberCleanup: rememberRoomInviteCleanup,
        consumeInvite: (inviteId) => updateRoomInvite("consume_room_invite", inviteId),
        clearCleanup: clearRoomInviteCleanup,
      });

      localStorage.setItem("spy_active_room_id", result.room.id);
      setState(stateWithoutRoomInvite(result.acceptedState || state, invite.id));
      setFeedback({ id: actionId, phase: "success", label: copy.ready });
      await wait(620);
      navigate(createPageUrl("Room") + `?id=${encodeURIComponent(result.room.id)}`);
    } catch (error) {
      if (acceptedState) setState(acceptedState);
      await showFailure(actionId, error);
      void refresh({ silent: true }).catch(() => {});
    }
  };

  const renderRelationshipActions = (profile) => {
    if (profile.id === state?.me?.id) {
      return <div className="community-status"><Check size={14} /> {copy.you}</div>;
    }
    const relationship = relationshipForProfile(state, profile.id);
    if (!relationship) {
      return (
        <ActionButton
          actionId={`friend-send-${profile.id}`}
          feedback={feedback}
          label={copy.add}
          icon={UserPlus}
          variant="primary"
          disabled={busy}
          onClick={() => handleSendRequest(profile)}
        />
      );
    }
    if (relationship.status === "accepted") {
      if (activeRoom) {
        return (
          <ActionButton
            actionId={`room-send-${profile.id}`}
            feedback={feedback}
            label={invitedProfileIds.has(profile.id) ? copy.invited : `${copy.invite} ${activeRoom.code}`}
            icon={Send}
            variant="primary"
            disabled={busy || invitedProfileIds.has(profile.id)}
            onClick={() => handleInvite(profile)}
          />
        );
      }
      return <div className="community-status community-status-green"><Check size={14} /> {copy.friend}</div>;
    }
    if (relationship.direction === "incoming") {
      return (
        <div className="community-actions">
          <ActionButton
            actionId={`friend-accept-${relationship.id}`}
            feedback={feedback}
            label={copy.accept}
            icon={Check}
            variant="primary"
            disabled={busy}
            onClick={() => handleFriendDecision(relationship, "accept")}
          />
          <ActionButton
            actionId={`friend-decline-${relationship.id}`}
            feedback={feedback}
            label={copy.decline}
            icon={X}
            disabled={busy}
            onClick={() => handleFriendDecision(relationship, "decline")}
          />
        </div>
      );
    }
    return <div className="community-status"><Clock3 size={14} /> {copy.sent}</div>;
  };

  return (
    <PageChrome eyebrow={copy.eyebrow} status={copy.online}>
      <style>{`
        .community-page { width: min(100%, 680px); margin: 0 auto; padding: 22px 18px 28px; }
        .community-hero { display:flex; align-items:flex-end; justify-content:space-between; gap:18px; margin-bottom:18px; }
        .community-hero h1 { font-family:'Rajdhani',sans-serif; font-size:clamp(24px,5vw,32px); line-height:.96; letter-spacing:1.5px; margin:0 0 9px; }
        .community-hero p { max-width:620px; color:#686868; font-size:11px; line-height:1.55; letter-spacing:.65px; }
        .community-search { display:flex; gap:9px; margin:18px 0; }
        .community-search-box { position:relative; flex:1; }
        .community-search-box svg { position:absolute; top:50%; left:14px; transform:translateY(-50%); color:#e53535; pointer-events:none; }
        .community-search-box input { min-height:50px; padding-left:43px; letter-spacing:1.5px; }
        .community-room-channel { padding:13px 15px; margin-bottom:16px; border:1px solid ${activeRoom ? "rgba(229,53,53,.45)" : "#202020"}; background:${activeRoom ? "rgba(229,53,53,.055)" : "#090909"}; display:flex; align-items:center; gap:12px; }
        .community-room-channel svg { color:${activeRoom ? "#e53535" : "#444"}; flex:none; }
        .community-room-channel strong { display:block; color:${activeRoom ? "#fff" : "#777"}; font-size:11px; letter-spacing:1.5px; }
        .community-room-channel span { display:block; color:#555; margin-top:3px; font-size:9px; letter-spacing:.7px; }
        .community-section { border:1px solid #1d1d1d; background:rgba(10,10,10,.88); margin-bottom:14px; position:relative; }
        .community-accent-line { position:absolute; left:-1px; top:-1px; width:18px; height:1px; }
        .community-section-head { display:flex; justify-content:space-between; align-items:center; padding:12px 14px; border-bottom:1px solid #1b1b1b; color:#777; font-size:9px; letter-spacing:2px; }
        .community-section-head strong { font-size:11px; }
        .community-section-body { padding:12px; }
        .community-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:10px; }
        .community-card { border:1px solid #202020; background:#0b0b0b; padding:12px; min-width:0; }
        .community-identity { display:flex; align-items:center; gap:10px; min-width:0; }
        .community-avatar { width:46px; height:46px; display:grid; place-items:center; border:1px solid #292929; background:#030303; font-size:23px; flex:none; }
        .community-identity-copy { min-width:0; flex:1; }
        .community-identity-copy strong { display:block; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:'Rajdhani',sans-serif; font-size:15px; letter-spacing:1.5px; }
        .community-identity-copy span { color:#696969; font-size:9px; letter-spacing:1.4px; }
        .community-stats { text-align:right; flex:none; }
        .community-stats span { display:block; color:#444; font-size:7px; letter-spacing:1px; }
        .community-stats strong { color:#e53535; font-size:12px; }
        .community-card-meta { display:flex; gap:14px; margin:11px 0; color:#505050; font-size:8px; letter-spacing:.9px; }
        .community-actions { display:flex; gap:7px; margin-top:11px; }
        .community-status { display:flex; align-items:center; justify-content:center; gap:7px; min-height:42px; margin-top:11px; border:1px solid #252525; color:#777; font-size:9px; letter-spacing:1.3px; }
        .community-status-green { color:#59c878; border-color:rgba(89,200,120,.3); }
        .community-message { margin:0 0 14px; padding:11px 13px; border:1px solid rgba(229,53,53,.4); color:#e53535; background:rgba(229,53,53,.06); font-size:10px; letter-spacing:.8px; }
        .community-empty { display:grid; place-items:center; min-height:92px; color:#505050; font-size:9px; letter-spacing:1.4px; text-align:center; }
        .community-loader { display:flex; align-items:center; justify-content:center; gap:9px; min-height:92px; color:#666; font-size:9px; letter-spacing:1.5px; }
        .community-loader svg { color:#e53535; animation:community-spin .9s linear infinite; }
        @keyframes community-spin { to { transform:rotate(360deg); } }
        @media (max-width:640px) {
          .community-page { padding-inline:14px; }
          .community-hero { align-items:flex-start; flex-direction:column; }
          .community-search { align-items:stretch; }
          .community-grid { grid-template-columns:1fr; }
          .community-grid-operatives { grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px; }
          .community-grid-operatives .community-card { padding:9px; }
          .community-grid-operatives .community-identity { gap:7px; align-items:flex-start; }
          .community-grid-operatives .community-avatar { width:36px; height:36px; font-size:19px; }
          .community-grid-operatives .community-identity-copy strong { font-size:12px; letter-spacing:1px; }
          .community-grid-operatives .community-identity-copy span { font-size:7px; letter-spacing:.8px; }
          .community-grid-operatives .community-stats { display:none; }
          .community-grid-operatives .community-card-meta { gap:7px; font-size:7px; }
          .community-grid-operatives .community-actions { flex-direction:column; }
        }
      `}</style>

      <main className="community-page">
        <header className="community-hero">
          <div>
            <h1>{copy.title}</h1>
            <p>{copy.subtitle}</p>
          </div>
        </header>

        {activeRoom && (
          <div className="community-room-channel">
            <DoorOpen size={20} />
            <div>
              <strong>{copy.activeRoom} · {copy.room} {activeRoom.code}</strong>
              <span>{relationships.friends.length} {copy.friends.toLowerCase()}</span>
            </div>
          </div>
        )}

        {message && <div className="community-message" role="alert">{message}</div>}

        {networkError && !state && (
          <Section title={copy.unavailable} count="!">
            <div className="community-empty">
              <button className="btn-outline" onClick={() => void refresh().catch(() => {})}>
                {copy.retry}
              </button>
            </div>
          </Section>
        )}

        {relationships.roomInvites.length > 0 && (
          <Section title={copy.roomInvites} count={relationships.roomInvites.length}>
            <div className="community-grid">
              {relationships.roomInvites.map((invite) => (
                <div className="community-card" key={invite.id}>
                  <Identity profile={invite.sender} copy={copy} />
                  <div className="community-card-meta">
                    <span>{copy.room}: <strong style={{ color: "#e53535" }}>{invite.room_code}</strong></span>
                  </div>
                  <div className="community-actions">
                    <ActionButton
                      actionId={`room-accept-${invite.id}`}
                      feedback={feedback}
                      label={copy.join}
                      icon={DoorOpen}
                      variant="primary"
                      disabled={busy}
                      onClick={() => void handleJoinRoomInvite(invite)}
                    />
                    <ActionButton
                      actionId={`room-decline-${invite.id}`}
                      feedback={feedback}
                      label={copy.decline}
                      icon={X}
                      disabled={busy}
                      onClick={() => void handleDeclineRoomInvite(invite)}
                    />
                  </div>
                </div>
              ))}
            </div>
          </Section>
        )}

        {relationships.incoming.length > 0 && (
          <Section title={copy.friendRequests} count={relationships.incoming.length} accent="#d99b35">
            <div className="community-grid">
              {relationships.incoming.map((record) => (
                <div className="community-card" key={record.id}>
                  <Identity profile={record.profile} copy={copy} />
                  <div className="community-actions">
                    <ActionButton
                      actionId={`friend-accept-${record.id}`}
                      feedback={feedback}
                      label={copy.accept}
                      icon={Check}
                      variant="primary"
                      disabled={busy}
                      onClick={() => void handleFriendDecision(record, "accept")}
                    />
                    <ActionButton
                      actionId={`friend-decline-${record.id}`}
                      feedback={feedback}
                      label={copy.decline}
                      icon={X}
                      disabled={busy}
                      onClick={() => void handleFriendDecision(record, "decline")}
                    />
                  </div>
                </div>
              ))}
            </div>
          </Section>
        )}

        <div className="community-search">
          <label className="community-search-box">
            <Search size={17} />
            <input
              type="search"
              value={query}
              placeholder={copy.search}
              onChange={(event) => setQuery(event.target.value.slice(0, 64))}
              aria-label={copy.search}
            />
          </label>
        </div>

        <Section title={copy.friends} count={relationships.friends.length} accent="#59c878">
          {relationships.friends.length === 0 ? (
            <div className="community-empty">{copy.noFriends}</div>
          ) : (
            <div className="community-grid community-grid-operatives">
              {relationships.friends.map((record) => (
                <div className="community-card" key={record.id}>
                  <Identity profile={record.profile} copy={copy} />
                  <div className="community-card-meta">
                    <span>{copy.games}: {record.profile.games_played || 0}</span>
                    <span>{copy.wins}: {record.profile.games_won || 0}</span>
                  </div>
                  {renderRelationshipActions(record.profile)}
                </div>
              ))}
            </div>
          )}
        </Section>

        {relationships.outgoing.length > 0 && (
          <Section title={copy.outgoing} count={relationships.outgoing.length} accent="#777">
            <div className="community-grid">
              {relationships.outgoing.map((record) => (
                <div className="community-card" key={record.id}>
                  <Identity profile={record.profile} copy={copy} />
                  <ActionButton
                    actionId={`friend-cancel-${record.id}`}
                    feedback={feedback}
                    label={copy.cancel}
                    icon={X}
                    disabled={busy}
                    onClick={() => void handleCancelRequest(record)}
                  />
                </div>
              ))}
            </div>
          </Section>
        )}

        <Section title={copy.directory} count={directory.length}>
          {directoryLoading || (isLoading && !state) ? (
            <div className="community-loader"><RefreshCw size={17} /> {copy.loading}</div>
          ) : directoryError ? (
            <div className="community-empty">{copy.unavailable}</div>
          ) : directory.length === 0 ? (
            <div className="community-empty">{copy.noResults}</div>
          ) : (
            <div className="community-grid community-grid-operatives">
              {directory.map((profile) => (
                <motion.div
                  className="community-card"
                  key={profile.id}
                  initial={{ opacity: 0, y: 8 }}
                  animate={{ opacity: 1, y: 0 }}
                >
                  <Identity profile={profile} copy={copy} />
                  <div className="community-card-meta">
                    <span>{copy.games}: {profile.games_played || 0}</span>
                    <span>{copy.wins}: {profile.games_won || 0}</span>
                  </div>
                  {renderRelationshipActions(profile)}
                </motion.div>
              ))}
            </div>
          )}
        </Section>
      </main>
    </PageChrome>
  );
}
