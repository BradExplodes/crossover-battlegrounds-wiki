(() => {
  const root = document.documentElement;
  const themeToggle = document.querySelector("[data-theme-toggle]");
  const themeKey = "cb-theme";

  const readStoredTheme = () => {
    try {
      const theme = localStorage.getItem(themeKey);
      return theme === "dark" || theme === "light" ? theme : "";
    } catch {
      return "";
    }
  };

  const writeStoredTheme = (theme) => {
    try {
      localStorage.setItem(themeKey, theme);
    } catch {}
  };

  const systemTheme = () => {
    if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) return "dark";
    return "light";
  };

  const currentTheme = () => root.dataset.theme || readStoredTheme() || systemTheme();

  const setTheme = (theme, persist) => {
    root.dataset.theme = theme;
    if (persist) writeStoredTheme(theme);
    if (themeToggle) {
      themeToggle.checked = theme === "dark";
      themeToggle.setAttribute("aria-label", theme === "dark" ? "Use light mode" : "Use dark mode");
    }
  };

  if (themeToggle) {
    setTheme(currentTheme(), false);
    themeToggle.addEventListener("change", () => setTheme(themeToggle.checked ? "dark" : "light", true));
  }

  const cards = [...document.querySelectorAll("[data-character-card]")];
  const search = document.querySelector("[data-filter-search]");
  const filters = [...document.querySelectorAll("[data-filter]")];
  const count = document.querySelector("[data-filter-count]");

  if (!cards.length || !search) return;

  const applyFilters = () => {
    const term = search.value.trim().toLowerCase();
    const active = Object.fromEntries(filters.map((filter) => [filter.dataset.filter, filter.value]));
    let shown = 0;

    for (const card of cards) {
      const matchesTerm = !term || card.dataset.name.includes(term) || card.dataset.archetype.includes(term);
      const matchesStars = !active.stars || card.dataset.stars === active.stars;
      const matchesArchetype = !active.archetype || card.dataset.archetype === active.archetype;
      const matchesRange = !active.range || card.dataset.range === active.range;
      const visible = matchesTerm && matchesStars && matchesArchetype && matchesRange;
      card.hidden = !visible;
      if (visible) shown += 1;
    }

    if (count) count.textContent = shown + " shown";
  };

  search.addEventListener("input", applyFilters);
  for (const filter of filters) filter.addEventListener("change", applyFilters);
})();
