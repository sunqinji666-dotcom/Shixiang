(() => {
  const state = { range: "7d", view: "sessions", data: null };
  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];
  const number = new Intl.NumberFormat("zh-CN");
  const dateTime = new Intl.DateTimeFormat("zh-CN", { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false });
  const escapeText = (value) => String(value ?? "");
  const formatDuration = (seconds) => {
    const value = Number(seconds || 0);
    if (value < 60) return `${value} 秒`;
    if (value < 3600) return `${Math.floor(value / 60)}分 ${value % 60}秒`;
    return `${Math.floor(value / 3600)}时 ${Math.floor((value % 3600) / 60)}分`;
  };
  const formatTime = (seconds) => dateTime.format(new Date(Number(seconds) * 1000));
  const visitorName = (id) => `访客 ${String(id || "").slice(-6).toUpperCase()}`;
  const isLive = (lastSeen) => Date.now() / 1000 - Number(lastSeen) < 300;
  const showToast = (message) => {
    const toast = $("[data-toast]");
    toast.textContent = message;
    toast.classList.add("show");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => toast.classList.remove("show"), 1600);
  };

  const metric = (key, value) => {
    const element = $(`[data-metric="${key}"]`);
    if (element) element.textContent = value;
  };

  const renderOverview = ({ overview, retentionDays, generatedAt }) => {
    metric("visitors", number.format(overview.visitors || 0));
    metric("sessions", number.format(overview.sessions || 0));
    metric("pageviews", number.format(overview.pageviews || 0));
    metric("avg_active_seconds", formatDuration(overview.avg_active_seconds));
    metric("bounce_rate", `${overview.bounce_rate || 0}%`);
    $("[data-live-count]").textContent = overview.live_sessions || 0;
    $("[data-retention]").textContent = retentionDays || 180;
    $("[data-updated]").textContent = `更新于 ${formatTime(generatedAt)}`;
  };

  const pointPath = (values, width, height, pad) => {
    const max = Math.max(1, ...values);
    const step = values.length > 1 ? (width - pad * 2) / (values.length - 1) : 0;
    return values.map((value, index) => {
      const x = pad + index * step;
      const y = height - pad - (Number(value) / max) * (height - pad * 2);
      return [x, y];
    });
  };

  const renderChart = (timeline) => {
    const svg = $("[data-chart]");
    const rows = timeline.length ? timeline : [{ bucket: "暂无", sessions: 0, visitors: 0 }];
    const width = 900, height = 270, pad = 35;
    const sessionPoints = pointPath(rows.map((row) => Number(row.sessions)), width, height, pad);
    const visitorPoints = pointPath(rows.map((row) => Number(row.visitors)), width, height, pad);
    const line = (points) => points.map(([x, y], index) => `${index ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
    const area = `${line(sessionPoints)} L${sessionPoints.at(-1)[0]},${height - pad} L${sessionPoints[0][0]},${height - pad} Z`;
    const labels = rows.map((row, index) => {
      if (rows.length > 10 && index % Math.ceil(rows.length / 8) !== 0 && index !== rows.length - 1) return "";
      const [x] = sessionPoints[index];
      return `<text class="chart-label" x="${x}" y="263" text-anchor="middle">${escapeText(String(row.bucket).slice(5))}</text>`;
    }).join("");
    const dots = sessionPoints.map(([x, y], index) => `<circle class="chart-dot" cx="${x}" cy="${y}" r="3"><title>${escapeText(rows[index].bucket)}：${rows[index].sessions} 次访问</title></circle>`).join("");
    const grids = [35, 85, 135, 185, 235].map((y) => `<line class="chart-grid" x1="35" y1="${y}" x2="865" y2="${y}"/>`).join("");
    svg.innerHTML = `<defs><linearGradient id="areaGradient" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8d63ff" stop-opacity=".24"/><stop offset="1" stop-color="#8d63ff" stop-opacity="0"/></linearGradient></defs>${grids}<path class="chart-area" d="${area}"/><path class="chart-line" d="${line(sessionPoints)}"/><path class="chart-visitor" d="${line(visitorPoints)}"/>${dots}${labels}`;
  };

  const renderRanks = (selector, rows, mode) => {
    const container = $(selector);
    if (!rows.length) {
      container.innerHTML = `<div class="empty-state">等待第一批访问数据</div>`;
      return;
    }
    const max = Math.max(...rows.map((row) => Number(mode === "pages" ? row.views : row.value)), 1);
    container.replaceChildren(...rows.map((row) => {
      const value = Number(mode === "pages" ? row.views : row.value);
      const element = document.createElement("div");
      element.className = "rank-row";
      const title = mode === "pages" ? (row.title || row.path) : row.label;
      const subtitle = mode === "pages" ? `${row.visitors} 位访客 · 平均 ${formatDuration(row.avg_seconds)}` : "访问来源";
      element.innerHTML = `<div class="rank-copy"><b></b><small></small></div><div class="rank-value"><strong>${number.format(value)}</strong><i>${mode === "pages" ? "浏览" : "会话"}</i></div><div class="rank-meter"><i style="width:${Math.max(4, value / max * 100)}%"></i></div>`;
      element.querySelector("b").textContent = title;
      element.querySelector("small").textContent = subtitle;
      return element;
    }));
  };

  const renderBars = (selector, rows) => {
    const container = $(selector);
    if (!rows.length) {
      container.innerHTML = `<div class="empty-state">暂无数据</div>`;
      return;
    }
    const total = rows.reduce((sum, row) => sum + Number(row.value), 0) || 1;
    container.replaceChildren(...rows.slice(0, 6).map((row) => {
      const percent = Math.round(Number(row.value) / total * 100);
      const element = document.createElement("div");
      element.className = "bar-row";
      element.innerHTML = `<b></b><span>${percent}%</span><div class="bar-track"><i style="width:${percent}%"></i></div>`;
      element.querySelector("b").textContent = row.label || "未知";
      return element;
    }));
  };

  const td = (value, className = "") => {
    const cell = document.createElement("td");
    if (className) cell.className = className;
    cell.textContent = value;
    return cell;
  };

  const renderTable = () => {
    const head = $("[data-table-head]");
    const body = $("[data-table-body]");
    const visitors = state.view === "visitors";
    const headers = visitors
      ? ["访客", "网络地址", "最后访问", "会话", "浏览", "活跃时间", "设备", "最后页面"]
      : ["状态", "访客", "网络地址", "进入时间", "活跃时间", "浏览", "设备环境", "入口", "当前页面"];
    const row = document.createElement("tr");
    headers.forEach((label) => { const th = document.createElement("th"); th.textContent = label; row.append(th); });
    head.replaceChildren(row);
    const records = visitors ? state.data.visitors : state.data.recent;
    if (!records.length) {
      const empty = document.createElement("tr");
      const cell = td("还没有访问数据");
      cell.colSpan = headers.length;
      empty.append(cell);
      body.replaceChildren(empty);
      return;
    }
    body.replaceChildren(...records.map((record) => {
      const tr = document.createElement("tr");
      if (visitors) {
        tr.append(td(visitorName(record.visitor_id), "visitor-id"), td(record.ip || "—"), td(formatTime(record.last_seen)), td(record.sessions), td(record.pageviews), td(formatDuration(record.active_seconds)), td(`${record.device} · ${record.os}`), td(record.current_path));
      } else {
        const status = td(isLive(record.last_seen) ? "正在访问" : "已离开", isLive(record.last_seen) ? "live-tag" : "");
        tr.append(status, td(visitorName(record.visitor_id), "visitor-id"), td(record.ip || "—"), td(formatTime(record.first_seen)), td(formatDuration(record.active_seconds)), td(record.pageviews), td(`${record.device} · ${record.os} · ${record.browser}`), td(record.entry_path), td(record.current_path));
      }
      return tr;
    }));
  };

  const render = (data) => {
    state.data = data;
    renderOverview(data);
    renderChart(data.timeline);
    renderRanks("[data-top-pages]", data.topPages, "pages");
    renderRanks("[data-sources]", data.sources, "sources");
    renderBars("[data-devices]", data.devices);
    renderBars("[data-systems]", data.systems);
    renderBars("[data-browsers]", data.browsers);
    renderBars("[data-languages]", data.languages);
    renderTable();
  };

  const load = async (notify = false) => {
    const button = $("[data-refresh]");
    button.classList.add("loading");
    try {
      const response = await fetch(`../admin-api.php?range=${state.range}`, { credentials: "same-origin", cache: "no-store" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      if (!data.ok) throw new Error(data.error || "加载失败");
      render(data);
      if (notify) showToast("数据已刷新");
    } catch (error) {
      showToast(`读取失败：${error.message}`);
    } finally {
      button.classList.remove("loading");
    }
  };

  $$('[data-range]').forEach((button) => button.addEventListener("click", () => {
    state.range = button.dataset.range;
    $$('[data-range]').forEach((item) => item.classList.toggle("active", item === button));
    load();
  }));
  $$('[data-view]').forEach((button) => button.addEventListener("click", () => {
    state.view = button.dataset.view;
    $$('[data-view]').forEach((item) => item.classList.toggle("active", item === button));
    if (state.data) renderTable();
  }));
  $("[data-refresh]").addEventListener("click", () => load(true));

  load();
  setInterval(() => load(), 30000);
})();
