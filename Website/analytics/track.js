(() => {
  if (navigator.doNotTrack === "1" || window.doNotTrack === "1" || location.pathname.startsWith("/analytics/admin")) return;

  const endpoint = "/analytics/collect.php";
  const now = Date.now();
  const makeId = () => crypto.randomUUID?.().replaceAll("-", "") || `${now.toString(36)}${Math.random().toString(36).slice(2)}${Math.random().toString(36).slice(2)}`;
  const getStored = (storage, key) => {
    try { return JSON.parse(storage.getItem(key) || "null"); } catch { return null; }
  };
  const setStored = (storage, key, value) => {
    try { storage.setItem(key, JSON.stringify(value)); } catch { /* private mode */ }
  };

  let visitorId = getStored(localStorage, "sx_visitor_id");
  if (typeof visitorId !== "string" || visitorId.length < 12) {
    visitorId = makeId();
    setStored(localStorage, "sx_visitor_id", visitorId);
  }

  let session = getStored(sessionStorage, "sx_session");
  if (!session || typeof session.id !== "string" || now - Number(session.lastSeen || 0) > 30 * 60 * 1000) {
    session = { id: makeId(), lastSeen: now };
  }
  session.lastSeen = now;
  setStored(sessionStorage, "sx_session", session);

  const pageId = makeId();
  const params = new URLSearchParams(location.search);
  const mobile = navigator.userAgentData?.mobile ?? matchMedia("(max-width: 760px)").matches;
  let activeSeconds = 0;
  let lastActivity = now;
  let sentExit = false;

  const payload = (event) => ({
    event,
    visitorId,
    sessionId: session.id,
    pageId,
    path: location.pathname.slice(0, 500),
    title: document.title,
    referrer: document.referrer,
    activeSeconds,
    language: navigator.language || "",
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "",
    screen: `${screen.width}×${screen.height}`,
    viewport: `${innerWidth}×${innerHeight}`,
    mobile,
    utmSource: params.get("utm_source") || "",
    utmMedium: params.get("utm_medium") || "",
    utmCampaign: params.get("utm_campaign") || ""
  });

  const send = (event, beacon = false) => {
    const body = JSON.stringify(payload(event));
    session.lastSeen = Date.now();
    setStored(sessionStorage, "sx_session", session);
    if (beacon && navigator.sendBeacon) {
      navigator.sendBeacon(endpoint, new Blob([body], { type: "application/json" }));
      return;
    }
    fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      credentials: "omit",
      keepalive: true
    }).catch(() => {});
  };

  const markActivity = () => { lastActivity = Date.now(); };
  ["pointerdown", "keydown", "scroll", "touchstart"].forEach((event) => addEventListener(event, markActivity, { passive: true }));

  send("pageview");
  const activityTimer = setInterval(() => {
    if (document.visibilityState === "visible" && Date.now() - lastActivity < 60000) activeSeconds += 1;
  }, 1000);
  const heartbeatTimer = setInterval(() => send("heartbeat"), 15000);

  const exit = () => {
    if (sentExit) return;
    sentExit = true;
    clearInterval(activityTimer);
    clearInterval(heartbeatTimer);
    send("exit", true);
  };
  addEventListener("pagehide", exit, { once: true });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") send("heartbeat", true);
    else markActivity();
  });
})();
