(() => {
  const sections = [...document.querySelectorAll('.guide-section[id]')];
  const links = [...document.querySelectorAll('[data-guide-nav] a')];
  const backTop = document.querySelector('[data-back-top]');
  const lightbox = document.querySelector('[data-lightbox-dialog]');
  const lightboxImage = lightbox?.querySelector('img');

  const updateNavigation = () => {
    const threshold = 150;
    let active = sections[0]?.id;
    for (const section of sections) {
      if (section.getBoundingClientRect().top <= threshold) active = section.id;
    }
    links.forEach(link => link.classList.toggle('active', link.hash === `#${active}`));
    backTop?.classList.toggle('visible', window.scrollY > 700);
  };

  window.addEventListener('scroll', updateNavigation, { passive: true });
  updateNavigation();

  document.querySelector('[data-print]')?.addEventListener('click', () => window.print());
  backTop?.addEventListener('click', () => window.scrollTo({ top: 0, behavior: 'smooth' }));

  document.querySelectorAll('[data-lightbox]').forEach(button => {
    button.addEventListener('click', () => {
      if (!lightbox || !lightboxImage) return;
      lightboxImage.src = button.dataset.lightbox;
      lightbox.hidden = false;
      document.body.style.overflow = 'hidden';
      lightbox.querySelector('button')?.focus();
    });
  });

  const closeLightbox = () => {
    if (!lightbox || !lightboxImage) return;
    lightbox.hidden = true;
    lightboxImage.removeAttribute('src');
    document.body.style.removeProperty('overflow');
  };

  document.querySelector('[data-lightbox-close]')?.addEventListener('click', closeLightbox);
  lightbox?.addEventListener('click', event => {
    if (event.target === lightbox) closeLightbox();
  });
  window.addEventListener('keydown', event => {
    if (event.key === 'Escape' && lightbox && !lightbox.hidden) closeLightbox();
  });
})();
