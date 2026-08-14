(() => {
  const config = window.SHIXIANG_SITE || {};
  const downloadLinks = document.querySelectorAll("[data-download-link]");
  const downloadLabels = document.querySelectorAll("[data-download-label]");
  const panCode = document.querySelector("[data-pan-code]");
  const panCodeValue = document.querySelector("[data-pan-code-value]");
  const copyCode = document.querySelector("[data-copy-code]");
  const downloadNote = document.querySelector("[data-download-note]");
  const toast = document.querySelector("[data-toast]");
  const downloadTransition = document.querySelector("[data-download-transition]");
  const downloadCountdown = document.querySelector("[data-download-countdown]");
  const downloadCancel = document.querySelector("[data-download-cancel]");
  const transitionCopyStatus = document.querySelector("[data-transition-copy-status]");
  const conceptFilm = document.querySelector("[data-concept-film]");
  const conceptFilmPlay = conceptFilm?.querySelector("[data-film-play]");
  const conceptFilmVideo = conceptFilm?.querySelector("[data-film-video]");
  let downloadCountdownTimer;
  let pendingDownloadURL;
  let downloadTrigger;

  const showToast = (message) => {
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add("show");
    window.clearTimeout(showToast.timeout);
    showToast.timeout = window.setTimeout(() => toast.classList.remove("show"), 1800);
  };

  downloadLabels.forEach((label) => {
    label.textContent = config.downloadLabel || "百度网盘下载";
  });

  downloadLinks.forEach((link) => {
    if (config.baiduPanUrl) {
      link.href = config.baiduPanUrl;
      link.target = "_self";
      link.addEventListener("click", (event) => {
        event.preventDefault();
        beginDownloadTransition(config.baiduPanUrl);
        if (!config.baiduPanCode) return;
        navigator.clipboard.writeText(config.baiduPanCode).then(() => {
          if (transitionCopyStatus) {
            transitionCopyStatus.innerHTML = `提取码 <strong>${config.baiduPanCode}</strong> 已复制`;
          }
          showToast(`提取码 ${config.baiduPanCode} 已复制`);
        }).catch(() => {
          if (transitionCopyStatus) {
            transitionCopyStatus.innerHTML = `请记住提取码 <strong>${config.baiduPanCode}</strong>`;
          }
          showToast(`提取码：${config.baiduPanCode}`);
        });
      });
    } else {
      link.addEventListener("click", (event) => {
        if (link.getAttribute("href") === "#download") return;
        event.preventDefault();
        document.querySelector("#download")?.scrollIntoView({ behavior: "smooth" });
        showToast("正式下载地址正在准备");
      });
    }
  });

  const renderCountdown = (value) => {
    if (!downloadCountdown) return;
    downloadCountdown.textContent = value;
    downloadCountdown.dataset.value = value;
    downloadCountdown.classList.remove("is-ticking");
    void downloadCountdown.offsetWidth;
    downloadCountdown.classList.add("is-ticking");
  };

  const closeDownloadTransition = () => {
    window.clearInterval(downloadCountdownTimer);
    downloadCountdownTimer = undefined;
    pendingDownloadURL = undefined;
    document.body.classList.remove("download-transition-open");
    downloadTransition?.classList.remove("is-visible");
    window.setTimeout(() => {
      if (downloadTransition && !downloadTransition.classList.contains("is-visible")) {
        downloadTransition.hidden = true;
        downloadTrigger?.focus({ preventScroll: true });
        downloadTrigger = undefined;
      }
    }, 300);
  };

  const beginDownloadTransition = (url) => {
    if (!downloadTransition || !downloadCountdown) {
      window.location.assign(url);
      return;
    }
    window.clearInterval(downloadCountdownTimer);
    pendingDownloadURL = url;
    downloadTrigger = document.activeElement instanceof HTMLElement ? document.activeElement : undefined;
    if (transitionCopyStatus) {
      transitionCopyStatus.innerHTML = `正在复制提取码 <strong>${config.baiduPanCode}</strong>…`;
    }
    downloadTransition.hidden = false;
    document.body.classList.add("download-transition-open");
    renderCountdown("3");
    window.setTimeout(() => downloadTransition.classList.add("is-visible"), 20);
    downloadCancel?.focus({ preventScroll: true });

    let remaining = 3;
    downloadCountdownTimer = window.setInterval(() => {
      remaining -= 1;
      if (remaining > 0) {
        renderCountdown(String(remaining));
        return;
      }
      window.clearInterval(downloadCountdownTimer);
      downloadCountdownTimer = undefined;
      const destination = pendingDownloadURL;
      pendingDownloadURL = undefined;
      renderCountdown("→");
      if (destination) {
        const readyEvent = new CustomEvent("shixiang:download-ready", {
          cancelable: true,
          detail: { url: destination }
        });
        if (window.dispatchEvent(readyEvent)) window.location.assign(destination);
      }
    }, 1000);
  };

  downloadCancel?.addEventListener("click", closeDownloadTransition);
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && downloadTransition && !downloadTransition.hidden) {
      closeDownloadTransition();
    }
  });

  if (config.baiduPanCode && panCode && panCodeValue) {
    panCode.hidden = false;
    panCodeValue.textContent = config.baiduPanCode;
    if (downloadNote) downloadNote.textContent = "点击下载会自动复制提取码，并打开百度网盘。";
  }

  copyCode?.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(config.baiduPanCode);
      showToast("提取码已复制");
    } catch {
      showToast(`提取码：${config.baiduPanCode}`);
    }
  });

  conceptFilmPlay?.addEventListener("click", () => {
    if (!conceptFilm || !conceptFilmVideo) return;
    const useMobileVideo = window.matchMedia("(max-width: 700px)").matches;
    const source = useMobileVideo
      ? conceptFilmVideo.dataset.srcMobile
      : conceptFilmVideo.dataset.srcDesktop;
    if (!conceptFilmVideo.src && source) {
      conceptFilmVideo.src = source;
      conceptFilmVideo.load();
    }
    conceptFilm.setAttribute("aria-busy", "true");
    conceptFilmVideo.hidden = false;
    requestAnimationFrame(() => conceptFilm.classList.add("is-playing"));
    conceptFilmVideo.addEventListener("loadeddata", () => {
      conceptFilm.removeAttribute("aria-busy");
    }, { once: true });
    window.setTimeout(() => {
      if (conceptFilm.classList.contains("is-playing")) conceptFilmPlay.hidden = true;
    }, 190);
    conceptFilmVideo.play().catch(() => {
      conceptFilm.removeAttribute("aria-busy");
    });
  });

  const header = document.querySelector("[data-header]");
  const updateHeader = () => header?.classList.toggle("scrolled", window.scrollY > 24);
  updateHeader();
  window.addEventListener("scroll", updateHeader, { passive: true });

})();
