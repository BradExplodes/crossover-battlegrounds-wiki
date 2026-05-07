import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const SOURCE = path.join(ROOT, "GameModule.lua");
const lua = readFileSync(SOURCE, "utf8");

const ARCHETYPE_TO_ABILITY = {
  money_farm: "base_money_farm",
  assassin: "base_assassin_burst",
  bruiser: "base_bruiser_sustain",
  tank: "base_tank_heal",
  buff: "base_buff_round",
  healer: "base_healer_aoe",
};

const STAR_TO_CATEGORY = {
  1: "one_star",
  2: "two_star",
  3: "three_star",
  4: "four_star",
};

const PLACEMENT_COST_TUNING = {
  2: { oldMin: 239, oldMax: 286, newMin: 200, newMax: 250 },
  3: { oldMin: 412, oldMax: 526, newMin: 350, newMax: 450 },
};

const MELEE_RANGE_HP_BUFF_THRESHOLD = 5;
const MELEE_RANGE_HP_BUFF_MULT = 1.25;

function ensureDir(dir) {
  mkdirSync(dir, { recursive: true });
}

function writePage(relativePath, content) {
  const target = path.join(ROOT, relativePath);
  ensureDir(path.dirname(target));
  writeFileSync(target, content, "utf8");
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("\n", " ");
}

function slug(value) {
  return String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function titleCase(value) {
  return String(value ?? "")
    .replaceAll("_", " ")
    .replace(/\b\w/g, (m) => m.toUpperCase());
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function remapAndClampCost(cost, stars) {
  const tuning = PLACEMENT_COST_TUNING[stars];
  if (!tuning) return cost;
  const alpha = (cost - tuning.oldMin) / (tuning.oldMax - tuning.oldMin);
  const mapped = tuning.newMin + alpha * (tuning.newMax - tuning.newMin);
  return clamp(Math.floor(mapped + 0.5), tuning.newMin, tuning.newMax);
}

function findMatchingBrace(source, openIndex) {
  let depth = 0;
  let quote = null;
  let inLineComment = false;
  let inBlockComment = false;

  for (let i = openIndex; i < source.length; i += 1) {
    const ch = source[i];
    const next = source[i + 1];
    const third = source[i + 2];
    const fourth = source[i + 3];

    if (inLineComment) {
      if (ch === "\n") inLineComment = false;
      continue;
    }

    if (inBlockComment) {
      if (ch === "]" && next === "]") {
        inBlockComment = false;
        i += 1;
      }
      continue;
    }

    if (quote) {
      if (ch === "\\" && next) {
        i += 1;
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }

    if (ch === "-" && next === "-") {
      if (third === "[" && fourth === "[") {
        inBlockComment = true;
        i += 3;
      } else {
        inLineComment = true;
        i += 1;
      }
      continue;
    }

    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }

    if (ch === "{") depth += 1;
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }

  throw new Error(`Unable to match brace at ${openIndex}`);
}

function extractBlockAfter(source, marker) {
  const markerIndex = source.indexOf(marker);
  if (markerIndex === -1) {
    throw new Error(`Missing block marker: ${marker}`);
  }
  const openIndex = source.indexOf("{", markerIndex);
  if (openIndex === -1) {
    throw new Error(`Missing opening brace after marker: ${marker}`);
  }
  const closeIndex = findMatchingBrace(source, openIndex);
  return source.slice(openIndex + 1, closeIndex);
}

function skipTrivia(source, index) {
  let i = index;
  while (i < source.length) {
    if (/\s|,/.test(source[i])) {
      i += 1;
      continue;
    }
    if (source[i] === "-" && source[i + 1] === "-") {
      if (source[i + 2] === "[" && source[i + 3] === "[") {
        const end = source.indexOf("]]", i + 4);
        i = end === -1 ? source.length : end + 2;
      } else {
        const end = source.indexOf("\n", i + 2);
        i = end === -1 ? source.length : end + 1;
      }
      continue;
    }
    break;
  }
  return i;
}

function parseNamedTables(block) {
  const result = {};
  let i = 0;

  while (i < block.length) {
    i = skipTrivia(block, i);
    const match = /^[A-Za-z_][A-Za-z0-9_]*/.exec(block.slice(i));
    if (!match) {
      i += 1;
      continue;
    }

    const key = match[0];
    let cursor = skipTrivia(block, i + key.length);
    if (block[cursor] !== "=") {
      i += key.length;
      continue;
    }
    cursor = skipTrivia(block, cursor + 1);
    if (block[cursor] !== "{") {
      i = cursor + 1;
      continue;
    }

    const close = findMatchingBrace(block, cursor);
    result[key] = block.slice(cursor + 1, close);
    i = close + 1;
  }

  return result;
}

function parseArrayTables(block) {
  const tables = [];
  let i = 0;

  while (i < block.length) {
    i = skipTrivia(block, i);
    if (block[i] !== "{") {
      i += 1;
      continue;
    }
    const close = findMatchingBrace(block, i);
    tables.push(block.slice(i + 1, close));
    i = close + 1;
  }

  return tables;
}

function matchString(block, key, fallback = "") {
  const re = new RegExp(`${key}\\s*=\\s*"([^"]*)"`);
  return re.exec(block)?.[1] ?? fallback;
}

function matchNumber(block, key, fallback = 0) {
  const re = new RegExp(`${key}\\s*=\\s*([0-9.]+)`);
  const value = re.exec(block)?.[1];
  return value == null ? fallback : Number(value);
}

function parseReward(block, key) {
  const re = new RegExp(`${key}\\s*=\\s*\\{\\s*money\\s*=\\s*([0-9.]+),\\s*gems\\s*=\\s*([0-9.]+),\\s*exp\\s*=\\s*([0-9.]+)\\s*\\}`);
  const match = re.exec(block);
  if (!match) return null;
  return {
    money: Number(match[1]),
    gems: Number(match[2]),
    exp: Number(match[3]),
  };
}

function parseColor(block) {
  const match = /themeColor\s*=\s*Color3\.fromRGB\((\d+),\s*(\d+),\s*(\d+)\)/.exec(block);
  if (!match) return null;
  return `rgb(${match[1]}, ${match[2]}, ${match[3]})`;
}

function parseRbxAssetId(value) {
  const match = /rbxassetid:\/\/([0-9]+)/.exec(value);
  return match?.[1] ?? "";
}

function robloxThumb(assetId, width = 768, height = 432) {
  if (!assetId) return "";
  return `https://www.roblox.com/asset-thumbnail/image?assetId=${assetId}&width=${width}&height=${height}&format=png`;
}

function parseKeyedNumbers(block) {
  const out = {};
  for (const match of block.matchAll(/([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([0-9.]+)/g)) {
    out[match[1]] = Number(match[2]);
  }
  return out;
}

function parseRoster() {
  const rosterBlock = extractBlockAfter(lua, "local ROSTER =");
  const units = [];
  const rowRe = /\{\s*id\s*=\s*"([^"]+)",\s*modelName\s*=\s*"([^"]+)",\s*displayName\s*=\s*"([^"]+)",\s*stars\s*=\s*(\d+),\s*archetype\s*=\s*"([^"]+)",\s*rangeMode\s*=\s*"([^"]+)",\s*stats\s*=\s*\{\s*health\s*=\s*([0-9.]+),\s*dmg\s*=\s*([0-9.]+),\s*as\s*=\s*([0-9.]+),\s*range\s*=\s*([0-9.]+),\s*cost\s*=\s*([0-9.]+),\s*move_speed\s*=\s*([0-9.]+)\s*\}\s*\}/g;

  for (const match of rosterBlock.matchAll(rowRe)) {
    const stars = Number(match[4]);
    const baseRange = Number(match[10]);
    let health = Number(match[7]);
    if (baseRange === MELEE_RANGE_HP_BUFF_THRESHOLD && health > 0) {
      health = Math.floor(health * MELEE_RANGE_HP_BUFF_MULT + 0.5);
    }

    let cost = Number(match[11]);
    cost = remapAndClampCost(cost, stars);

    const dmg = Number(match[8]);
    const attackSpeed = Number(match[9]);
    const id = match[1];
    const archetype = match[5];
    const rangeMode = match[6];
    const abilityId = ARCHETYPE_TO_ABILITY[archetype] ?? "default_burst";

    units.push({
      id,
      modelName: match[2],
      name: match[3],
      stars,
      category: STAR_TO_CATEGORY[stars] ?? "one_star",
      archetype,
      archetypeLabel: titleCase(archetype),
      rangeMode,
      rangeModeLabel: titleCase(rangeMode),
      abilityId,
      stats: {
        health,
        dmg,
        attackSpeed,
        range: baseRange,
        cost,
        moveSpeed: Number(match[12]),
        dps: attackSpeed > 0 ? dmg / attackSpeed : 0,
      },
    });
  }

  return units;
}

function parseMaps(moduleBlock) {
  const mapsBlock = extractBlockAfter(moduleBlock, "Maps =");
  return Object.entries(parseNamedTables(mapsBlock)).map(([id, block]) => ({
    id,
    name: matchString(block, "displayName", id),
    modelName: matchString(block, "modelName", ""),
  }));
}

function parseAbilities(moduleBlock) {
  const abilitiesBlock = extractBlockAfter(moduleBlock, "Abilities =");
  return Object.fromEntries(Object.entries(parseNamedTables(abilitiesBlock)).map(([id, block]) => [
    id,
    {
      id,
      name: matchString(block, "displayName", titleCase(id)),
      description: matchString(block, "description", ""),
      behavior: matchString(block, "behavior", ""),
      numbers: parseKeyedNumbers(block),
    },
  ]));
}

function parseStory(moduleBlock) {
  const storyBlock = extractBlockAfter(moduleBlock, "StoryMode =");
  const hardcoreBlock = extractBlockAfter(storyBlock, "hardcore =");
  const worldsBlock = extractBlockAfter(storyBlock, "Worlds =");

  return {
    storyPlaceId: matchNumber(storyBlock, "storyPlaceId"),
    actsPerWorld: matchNumber(storyBlock, "actsPerWorld"),
    firstClearExpMultiplier: matchNumber(storyBlock, "firstClearExpMultiplier", 1),
    hardcore: {
      difficultyMultiplier: matchNumber(hardcoreBlock, "difficultyMultiplier", 2),
      rewardMultiplier: matchNumber(hardcoreBlock, "rewardMultiplier", 2),
    },
    worlds: parseArrayTables(worldsBlock).map((worldBlock) => {
      const actsBlock = extractBlockAfter(worldBlock, "acts =");
      const imageRaw = matchString(worldBlock, "worldImage", "");
      const imageAssetId = parseRbxAssetId(imageRaw);
      return {
        id: matchString(worldBlock, "id"),
        order: matchNumber(worldBlock, "order"),
        name: matchString(worldBlock, "displayName"),
        subtitle: matchString(worldBlock, "subtitle"),
        color: parseColor(worldBlock),
        imageAssetId,
        imageUrl: robloxThumb(imageAssetId),
        mapKey: matchString(worldBlock, "mapKey"),
        acts: parseArrayTables(actsBlock).map((actBlock) => {
          const bossBlock = extractBlockAfter(actBlock, "boss =");
          return {
            act: matchNumber(actBlock, "act"),
            waves: matchNumber(actBlock, "waves"),
            baseDifficulty: matchNumber(actBlock, "baseDifficulty"),
            rewardsSummary: matchString(actBlock, "rewardsSummary"),
            boss: {
              style: matchString(bossBlock, "style"),
              unitId: matchString(bossBlock, "unitId", ""),
              modelScale: matchNumber(bossBlock, "modelScale", 1),
              statMultiplier: matchNumber(bossBlock, "statMultiplier", 1),
            },
            firstClearBonus: parseReward(actBlock, "firstClearBonus"),
            firstClearBonusHardcore: parseReward(actBlock, "firstClearBonusHardcore"),
          };
        }),
      };
    }),
  };
}

function parseMutations(moduleBlock) {
  const mutationsBlock = extractBlockAfter(moduleBlock, "Mutations =");
  return Object.entries(parseNamedTables(mutationsBlock)).map(([id, block]) => {
    const statsBlock = extractBlockAfter(block, "statMultipliers =");
    const gradientBlock = extractBlockAfter(block, "gradient =");
    const gradient = [...gradientBlock.matchAll(/"([A-Fa-f0-9]{6})"/g)].map((m) => `#${m[1]}`);
    return {
      id,
      name: matchString(block, "displayName", titleCase(id)),
      chanceDenominator: matchNumber(block, "chanceDenominator"),
      statMultipliers: parseKeyedNumbers(statsBlock),
      gradient,
    };
  });
}

function parsePlacementRules(moduleBlock) {
  const placementBlock = extractBlockAfter(moduleBlock, "PlacementRules =");
  return {
    maxUnitsPerPlayer: matchNumber(placementBlock, "maxUnitsPerPlayer"),
    maxCopiesPerUnitId: matchNumber(placementBlock, "maxCopiesPerUnitId"),
  };
}

function parseBattleTutorial(moduleBlock) {
  const tutorialBlock = extractBlockAfter(moduleBlock, "BattleTutorial =");
  return {
    tutorialPlaceId: matchNumber(tutorialBlock, "tutorialPlaceId"),
    returnLobbyPlaceId: matchNumber(tutorialBlock, "returnLobbyPlaceId"),
  };
}

const moduleBlock = extractBlockAfter(lua, "local module =");
const roster = parseRoster();
const maps = parseMaps(moduleBlock);
const abilities = parseAbilities(moduleBlock);
const story = parseStory(moduleBlock);
const mutations = parseMutations(moduleBlock);
const placementRules = parsePlacementRules(moduleBlock);
const battleTutorial = parseBattleTutorial(moduleBlock);
const rewardPayoutMult = matchNumber(moduleBlock, "REWARD_PAYOUT_MULT", 1);
const gemRewardPayoutMult = /module\.GEM_REWARD_PAYOUT_MULT\s*=\s*([0-9.]+)/.exec(lua)?.[1] ?? "1";

const mapByKey = Object.fromEntries(maps.map((m) => [m.id, m]));
const unitById = Object.fromEntries(roster.map((u) => [u.id, u]));
const maxStats = {
  health: Math.max(...roster.map((u) => u.stats.health)),
  dmg: Math.max(...roster.map((u) => u.stats.dmg)),
  dps: Math.max(...roster.map((u) => u.stats.dps)),
  range: Math.max(...roster.map((u) => u.stats.range)),
  moveSpeed: Math.max(...roster.map((u) => u.stats.moveSpeed)),
};

const counts = {
  total: roster.length,
  stars: Object.fromEntries([1, 2, 3, 4].map((stars) => [stars, roster.filter((u) => u.stars === stars).length])),
  archetypes: Object.fromEntries([...new Set(roster.map((u) => u.archetype))].sort().map((a) => [a, roster.filter((u) => u.archetype === a).length])),
};

function rel(depth, target) {
  return `${"../".repeat(depth)}${target}`;
}

function nav(depth, active = "") {
  const items = [
    ["Home", "index.html", "home"],
    ["Start Here", "getting-started/index.html", "start"],
    ["Characters", "characters/index.html", "characters"],
    ["Story", "story/index.html", "story"],
    ["Mechanics", "mechanics/index.html", "mechanics"],
    ["Mutations", "mutations/index.html", "mutations"],
  ];

  return `
    <header class="site-header">
      <a class="brand" href="${rel(depth, "index.html")}" aria-label="Crossover Battlegrounds Wiki home">
        <span class="brand-mark">CB</span>
        <span>Crossover Battlegrounds</span>
      </a>
      <div class="header-actions">
        <nav class="site-nav" aria-label="Primary">
          ${items.map(([label, href, key]) => `<a class="${active === key ? "active" : ""}" href="${rel(depth, href)}">${label}</a>`).join("")}
        </nav>
        <label class="theme-switch" title="Toggle dark mode">
          <input type="checkbox" data-theme-toggle aria-label="Toggle dark mode">
          <span aria-hidden="true"><span>L</span><span>D</span></span>
        </label>
      </div>
    </header>`;
}

function footer(depth) {
  return `
    <footer class="site-footer">
      <div>
        <strong>Crossover Battlegrounds Wiki</strong>
        <span>Static pages generated from GameModule.lua.</span>
      </div>
      <div class="footer-links">
        <a href="${rel(depth, "abilities/index.html")}">Abilities</a>
        <a href="${rel(depth, "maps/index.html")}">Maps</a>
        <a href="${rel(depth, "characters/index.html")}">Roster</a>
      </div>
    </footer>`;
}

function layout({ title, description, active, depth = 0, body, extraHead = "" }) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)} | Crossover Battlegrounds Wiki</title>
  <meta name="description" content="${escapeAttr(description)}">
  <script>
    try {
      const theme = localStorage.getItem("cb-theme");
      if (theme === "dark" || theme === "light") document.documentElement.dataset.theme = theme;
    } catch {}
  </script>
  <link rel="stylesheet" href="${rel(depth, "assets/styles.css")}">
  <link rel="icon" href="${rel(depth, "assets/favicon.svg")}" type="image/svg+xml">
  ${extraHead}
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  ${nav(depth, active)}
  <main id="main">
    ${body}
  </main>
  ${footer(depth)}
  <script src="${rel(depth, "assets/site.js")}" defer></script>
</body>
</html>
`;
}

function stars(count) {
  return `<span class="stars">${count}-Star</span>`;
}

function statValue(value, digits = 0) {
  return Number(value).toLocaleString("en", {
    maximumFractionDigits: digits,
    minimumFractionDigits: digits,
  });
}

function percent(value, max) {
  return `${Math.max(4, Math.min(100, (value / max) * 100)).toFixed(1)}%`;
}

function initials(name) {
  const parts = String(name).replace(/\([^)]*\)/g, "").split(/\s+/).filter(Boolean);
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return `${parts[0][0]}${parts[parts.length - 1][0]}`.toUpperCase();
}

function roleBlurb(unit) {
  const range = unit.rangeMode === "melee" ? "frontline" : "backline";
  const role = {
    assassin: "burst damage dealer",
    bruiser: "sustained fighter",
    tank: "durable anchor",
    buff: "team support",
    healer: "recovery support",
    money_farm: "economy unit",
  }[unit.archetype] ?? "fighter";
  return `${unit.name} is a ${range} ${role}.`;
}

function abilityText(ability) {
  if (!ability) return "";
  const bits = [];
  if (ability.numbers.multMin && ability.numbers.multMax) bits.push(`${ability.numbers.multMin}x-${ability.numbers.multMax}x damage`);
  if (ability.numbers.damageMult) bits.push(`${ability.numbers.damageMult}x damage`);
  if (ability.numbers.selfHealFrac) bits.push(`${Math.round(ability.numbers.selfHealFrac * 100)}% self heal`);
  if (ability.numbers.healFrac) bits.push(`${Math.round(ability.numbers.healFrac * 100)}% heal`);
  if (ability.numbers.buffFrac) bits.push(`${Math.round(ability.numbers.buffFrac * 100)}% damage buff`);
  if (ability.numbers.amount) bits.push(`${ability.numbers.amount} money`);
  return bits.length ? `<span class="small-note">${bits.join(" / ")}</span>` : "";
}

function statBars(unit) {
  const stats = [
    ["Health", unit.stats.health, maxStats.health, statValue(unit.stats.health)],
    ["Damage", unit.stats.dmg, maxStats.dmg, statValue(unit.stats.dmg)],
    ["DPS", unit.stats.dps, maxStats.dps, statValue(unit.stats.dps, 1)],
    ["Range", unit.stats.range, maxStats.range, statValue(unit.stats.range)],
    ["Move speed", unit.stats.moveSpeed, maxStats.moveSpeed, statValue(unit.stats.moveSpeed, 1)],
  ];

  return `<div class="stat-bars">
    ${stats.map(([label, value, max, shown]) => `
      <div class="bar-row">
        <span>${label}</span>
        <strong>${shown}</strong>
        <div class="bar-track" aria-hidden="true"><span style="width:${percent(value, max)}"></span></div>
      </div>`).join("")}
  </div>`;
}

function unitCard(unit, depth) {
  const ability = abilities[unit.abilityId];
  return `<a class="unit-card star-${unit.stars}" href="${rel(depth, `characters/${unit.id}/index.html`)}"
    data-character-card
    data-name="${escapeAttr(unit.name.toLowerCase())}"
    data-stars="${unit.stars}"
    data-archetype="${escapeAttr(unit.archetype)}"
    data-range="${escapeAttr(unit.rangeMode)}">
    <span class="avatar" aria-hidden="true">${escapeHtml(initials(unit.name))}</span>
    <span class="unit-meta">${stars(unit.stars)} <span>${escapeHtml(unit.archetypeLabel)}</span></span>
    <h2>${escapeHtml(unit.name)}</h2>
    <p>${escapeHtml(roleBlurb(unit))}</p>
    <dl class="mini-stats">
      <div><dt>HP</dt><dd>${statValue(unit.stats.health)}</dd></div>
      <div><dt>DMG</dt><dd>${statValue(unit.stats.dmg)}</dd></div>
      <div><dt>Cost</dt><dd>${statValue(unit.stats.cost)}</dd></div>
    </dl>
    <span class="ability-line">${escapeHtml(ability?.name ?? "Mana Burst")}</span>
  </a>`;
}

function rewardPills(reward) {
  if (!reward) return "";
  return `<span>${statValue(reward.money)} Coins</span><span>${statValue(reward.gems)} Gems</span><span>${statValue(reward.exp)} Exp</span>`;
}

function bossLabel(boss) {
  if (!boss) return "Boss wave";
  if (boss.style === "boss_unit") {
    return `Final boss wave (${boss.statMultiplier}x stats)`;
  }
  return `Stat-buffed boss wave (${boss.statMultiplier}x)`;
}

function homePage() {
  const heroWorld = story.worlds[0];
  const featured = [...roster].sort((a, b) => b.stars - a.stars || b.stats.dps - a.stats.dps).slice(0, 8);
  const heroStyle = heroWorld?.imageUrl ? ` style="--hero-image: url('${heroWorld.imageUrl}')"` : "";

  return layout({
    title: "Home",
    description: "Player-facing wiki for Crossover Battlegrounds, including characters, story worlds, mutations, abilities, and core mechanics.",
    active: "home",
    body: `
      <section class="hero"${heroStyle}>
        <div class="hero-content">
          <p class="eyebrow">Player Wiki</p>
          <h1>Crossover Battlegrounds</h1>
          <p class="hero-copy">Roster stats, story rewards, mutations, abilities, and run mechanics in one GitHub Pages-friendly guide.</p>
          <div class="hero-actions">
            <a class="primary-link" href="characters/index.html">Browse Characters</a>
            <a class="secondary-link" href="getting-started/index.html">Start Here</a>
          </div>
        </div>
      </section>

      <section class="summary-strip" aria-label="Wiki summary">
        <div><strong>${counts.total}</strong><span>Characters</span></div>
        <div><strong>${story.worlds.length}</strong><span>Story Worlds</span></div>
        <div><strong>${mutations.length}</strong><span>Mutations</span></div>
        <div><strong>${Object.keys(abilities).length}</strong><span>Abilities</span></div>
      </section>

      <section class="page-section">
        <div class="section-heading">
          <p class="eyebrow">Explore</p>
          <h2>Core Wiki Pages</h2>
        </div>
        <div class="link-grid">
          ${[
            ["Characters", "Full roster with individual stat pages.", "characters/index.html"],
            ["Story Mode", "World unlocks, act rewards, waves, and bosses.", "story/index.html"],
            ["Mechanics", "Placement limits, infinite mode, payouts, and combat basics.", "mechanics/index.html"],
            ["Mutations", "Mutation chances and stat multipliers.", "mutations/index.html"],
            ["Abilities", "Mana abilities by role and behavior.", "abilities/index.html"],
            ["Maps", "Map keys and story world locations.", "maps/index.html"],
          ].map(([title, copy, href]) => `
            <a class="feature-link" href="${href}">
              <span>${escapeHtml(title)}</span>
              <p>${escapeHtml(copy)}</p>
            </a>`).join("")}
        </div>
      </section>

      <section class="page-section alt-band">
        <div class="section-heading">
          <p class="eyebrow">Featured</p>
          <h2>Top-Rarity Units</h2>
        </div>
        <div class="unit-grid compact">
          ${featured.map((unit) => unitCard(unit, 0)).join("")}
        </div>
      </section>
    `,
  });
}

function charactersIndexPage() {
  const filters = {
    stars: [4, 3, 2, 1],
    archetypes: [...new Set(roster.map((u) => u.archetype))].sort(),
    ranges: [...new Set(roster.map((u) => u.rangeMode))].sort(),
  };

  return layout({
    title: "Characters",
    description: "Complete character roster for Crossover Battlegrounds with stats, roles, abilities, costs, and individual pages.",
    active: "characters",
    depth: 1,
    body: `
      <section class="subhero">
        <p class="eyebrow">Roster</p>
        <h1>Characters</h1>
        <p>${counts.total} playable units across ${filters.archetypes.length} roles.</p>
      </section>

      <section class="tools-panel" aria-label="Character filters">
        <label class="search-box">
          <span>Search</span>
          <input type="search" data-filter-search placeholder="Name or role">
        </label>
        <label>
          <span>Stars</span>
          <select data-filter="stars">
            <option value="">All</option>
            ${filters.stars.map((value) => `<option value="${value}">${value} Star</option>`).join("")}
          </select>
        </label>
        <label>
          <span>Role</span>
          <select data-filter="archetype">
            <option value="">All</option>
            ${filters.archetypes.map((value) => `<option value="${value}">${escapeHtml(titleCase(value))}</option>`).join("")}
          </select>
        </label>
        <label>
          <span>Range</span>
          <select data-filter="range">
            <option value="">All</option>
            ${filters.ranges.map((value) => `<option value="${value}">${escapeHtml(titleCase(value))}</option>`).join("")}
          </select>
        </label>
        <output class="result-count" data-filter-count>${counts.total} shown</output>
      </section>

      <section class="page-section">
        <div class="unit-grid" data-character-list>
          ${roster.map((unit) => unitCard(unit, 1)).join("")}
        </div>
      </section>
    `,
  });
}

function characterPage(unit) {
  const ability = abilities[unit.abilityId] ?? abilities.default_burst;
  const related = roster
    .filter((candidate) => candidate.id !== unit.id && candidate.archetype === unit.archetype)
    .sort((a, b) => b.stars - a.stars || a.name.localeCompare(b.name))
    .slice(0, 4);

  const mutationRows = mutations.map((mutation) => {
    const health = Math.floor(unit.stats.health * (mutation.statMultipliers.health ?? 1) + 0.5);
    const dmg = Math.floor(unit.stats.dmg * (mutation.statMultipliers.dmg ?? 1) + 0.5);
    const range = unit.stats.range * (mutation.statMultipliers.range ?? 1);
    return `
      <tr>
        <th>${escapeHtml(mutation.name)}</th>
        <td>${statValue(health)}</td>
        <td>${statValue(dmg)}</td>
        <td>${statValue(range, 1)}</td>
        <td>1/${statValue(mutation.chanceDenominator)}</td>
      </tr>`;
  }).join("");

  return layout({
    title: unit.name,
    description: `${unit.name} stats, role, ability, cost, and mutation preview for Crossover Battlegrounds.`,
    active: "characters",
    depth: 2,
    body: `
      <section class="character-hero star-${unit.stars}">
        <div class="breadcrumb"><a href="../../characters/index.html">Characters</a><span>${escapeHtml(unit.name)}</span></div>
        <div class="character-title">
          <span class="avatar large" aria-hidden="true">${escapeHtml(initials(unit.name))}</span>
          <div>
            <p class="eyebrow">${stars(unit.stars)} ${escapeHtml(unit.archetypeLabel)} | ${escapeHtml(unit.rangeModeLabel)}</p>
            <h1>${escapeHtml(unit.name)}</h1>
            <p>${escapeHtml(roleBlurb(unit))}</p>
          </div>
        </div>
        <dl class="hero-stats">
          <div><dt>Health</dt><dd>${statValue(unit.stats.health)}</dd></div>
          <div><dt>Damage</dt><dd>${statValue(unit.stats.dmg)}</dd></div>
          <div><dt>Attack Speed</dt><dd>${statValue(unit.stats.attackSpeed, 2)}</dd></div>
          <div><dt>Cost</dt><dd>${statValue(unit.stats.cost)}</dd></div>
        </dl>
      </section>

      <section class="two-column page-section">
        <article>
          <div class="section-heading">
            <p class="eyebrow">Combat Profile</p>
            <h2>Stats</h2>
          </div>
          ${statBars(unit)}
        </article>
        <article class="info-panel">
          <p class="eyebrow">Mana Ability</p>
          <h2>${escapeHtml(ability?.name ?? "Mana Burst")}</h2>
          <p>${escapeHtml(ability?.description ?? "")}</p>
          ${abilityText(ability)}
          <dl class="detail-list">
            <div><dt>Approx DPS</dt><dd>${statValue(unit.stats.dps, 1)}</dd></div>
            <div><dt>Copies Allowed</dt><dd>${placementRules.maxCopiesPerUnitId}</dd></div>
          </dl>
        </article>
      </section>

      <section class="page-section alt-band">
        <div class="section-heading">
          <p class="eyebrow">Mutation Preview</p>
          <h2>Mutated Stats</h2>
        </div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Mutation</th><th>Health</th><th>Damage</th><th>Range</th><th>Chance</th></tr></thead>
            <tbody>${mutationRows}</tbody>
          </table>
        </div>
      </section>

      <section class="page-section">
        <div class="section-heading">
          <p class="eyebrow">Similar Role</p>
          <h2>More ${escapeHtml(unit.archetypeLabel)} Units</h2>
        </div>
        <div class="unit-grid compact">
          ${related.map((candidate) => unitCard(candidate, 2)).join("")}
        </div>
      </section>
    `,
  });
}

function storyPage() {
  return layout({
    title: "Story Mode",
    description: "Crossover Battlegrounds story worlds, act waves, rewards, boss waves, hardcore scaling, and unlock rules.",
    active: "story",
    depth: 1,
    body: `
      <section class="subhero">
        <p class="eyebrow">Story Mode</p>
        <h1>Worlds And Acts</h1>
        <p>Clear acts in order, complete a world to open the next one, and use Hardcore for ${story.hardcore.difficultyMultiplier}x difficulty with ${story.hardcore.rewardMultiplier}x first-clear rewards.</p>
      </section>

      <section class="summary-strip local" aria-label="Story summary">
        <div><strong>${story.worlds.length}</strong><span>Worlds</span></div>
        <div><strong>${story.actsPerWorld}</strong><span>Acts Per World</span></div>
        <div><strong>${story.firstClearExpMultiplier}x</strong><span>First-Clear Exp</span></div>
        <div><strong>${story.hardcore.rewardMultiplier}x</strong><span>Hardcore Rewards</span></div>
      </section>

      ${story.worlds.map((world) => `
        <section class="world-section" id="${escapeAttr(world.id)}">
          <div class="world-heading" style="--world-color:${world.color ?? "#5a8dee"}; --world-image:url('${world.imageUrl}')">
            <div>
              <p class="eyebrow">World ${world.order}</p>
              <h2>${escapeHtml(world.name)}</h2>
              <p>${escapeHtml(world.subtitle)} | Map: ${escapeHtml(mapByKey[world.mapKey]?.name ?? world.mapKey)}</p>
            </div>
          </div>
          <div class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Act</th>
                  <th>Waves</th>
                  <th>Base Difficulty</th>
                  <th>Boss</th>
                  <th>Normal First Clear</th>
                  <th>Hardcore First Clear</th>
                </tr>
              </thead>
              <tbody>
                ${world.acts.map((act) => `
                  <tr>
                    <td>Act ${act.act}</td>
                    <td>${act.waves}</td>
                    <td>${act.baseDifficulty}</td>
                    <td>${escapeHtml(bossLabel(act.boss))}</td>
                    <td class="reward-cell">${rewardPills(act.firstClearBonus)}</td>
                    <td class="reward-cell">${rewardPills(act.firstClearBonusHardcore)}</td>
                  </tr>`).join("")}
              </tbody>
            </table>
          </div>
        </section>`).join("")}
    `,
  });
}

function mechanicsPage() {
  const roles = Object.entries(counts.archetypes).map(([role, count]) => {
    const ability = abilities[ARCHETYPE_TO_ABILITY[role]];
    return `
      <tr>
        <th>${escapeHtml(titleCase(role))}</th>
        <td>${count}</td>
        <td>${escapeHtml(ability?.name ?? "")}</td>
        <td>${escapeHtml(ability?.description ?? "")}</td>
      </tr>`;
  }).join("");

  return layout({
    title: "Mechanics",
    description: "Crossover Battlegrounds mechanics covering placement limits, combat stats, infinite mode, rewards, co-op scaling, and progression.",
    active: "mechanics",
    depth: 1,
    body: `
      <section class="subhero">
        <p class="eyebrow">Game Systems</p>
        <h1>Mechanics</h1>
        <p>Placement, roles, mana abilities, story unlocks, infinite phases, and reward scaling.</p>
      </section>

      <section class="page-section mechanics-grid">
        <article class="info-panel">
          <p class="eyebrow">Placement</p>
          <h2>Unit Limits</h2>
          <dl class="detail-list">
            <div><dt>Max units per player</dt><dd>${placementRules.maxUnitsPerPlayer}</dd></div>
            <div><dt>Max copies per unit</dt><dd>${placementRules.maxCopiesPerUnitId}</dd></div>
            <div><dt>Battle tutorial place</dt><dd>${battleTutorial.tutorialPlaceId}</dd></div>
          </dl>
        </article>
        <article class="info-panel">
          <p class="eyebrow">Rewards</p>
          <h2>Payout Multipliers</h2>
          <dl class="detail-list">
            <div><dt>Coin / Exp payout</dt><dd>${Math.round(rewardPayoutMult * 100)}%</dd></div>
            <div><dt>Gem reward payout</dt><dd>${Math.round(Number(gemRewardPayoutMult) * 100)}%</dd></div>
            <div><dt>Legacy wave clear</dt><dd>200 + wave x 60 + sqrt(difficulty) x 30</dd></div>
          </dl>
        </article>
        <article class="info-panel">
          <p class="eyebrow">Infinite</p>
          <h2>Run Flow</h2>
          <ol class="clean-list">
            <li>Pregame countdown gives players time to place units.</li>
            <li>Combat starts the wave and resolves until one side is wiped.</li>
            <li>Wave clear grants session money and opens intermission voting.</li>
            <li>Defeat ends the run and grants profile money scaled by wave and difficulty.</li>
          </ol>
        </article>
        <article class="info-panel">
          <p class="eyebrow">Co-op</p>
          <h2>Enemy Scaling</h2>
          <p>Co-op increases spawn count with a sublinear multiplier: 1 + 0.5 x (players - 1). Enemy health, damage, and attack speed match solo at the same wave and difficulty.</p>
        </article>
      </section>

      <section class="page-section alt-band">
        <div class="section-heading">
          <p class="eyebrow">Roles</p>
          <h2>Archetypes And Mana Abilities</h2>
        </div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>Role</th><th>Units</th><th>Ability</th><th>Effect</th></tr></thead>
            <tbody>${roles}</tbody>
          </table>
        </div>
      </section>

      <section class="page-section">
        <div class="section-heading">
          <p class="eyebrow">Stats</p>
          <h2>Combat Stat Glossary</h2>
        </div>
        <div class="glossary-grid">
          ${[
            ["Health", "How much damage a unit can take before being defeated."],
            ["Damage", "Base hit damage before ability bursts, buffs, and mutation multipliers."],
            ["Attack Speed", "Attack interval value used by combat. Lower values attack more often."],
            ["Range", "Attack reach. Melee units use 5 range in the module."],
            ["Cost", "In-run placement cost after module cost tuning."],
            ["Move Speed", "How quickly the unit moves through the battlefield."],
          ].map(([term, copy]) => `<article><h3>${term}</h3><p>${copy}</p></article>`).join("")}
        </div>
      </section>
    `,
  });
}

function mutationsPage() {
  return layout({
    title: "Mutations",
    description: "Crossover Battlegrounds mutation chances, stat multipliers, and visual themes.",
    active: "mutations",
    depth: 1,
    body: `
      <section class="subhero">
        <p class="eyebrow">Collection</p>
        <h1>Mutations</h1>
        <p>Rare unit variants that multiply combat stats.</p>
      </section>

      <section class="page-section mutation-grid">
        ${mutations.map((mutation) => `
          <article class="mutation-card" style="--mutation-gradient:${mutation.gradient.join(", ")}">
            <div class="mutation-swatch" aria-hidden="true"></div>
            <p class="eyebrow">1/${statValue(mutation.chanceDenominator)} Chance</p>
            <h2>${escapeHtml(mutation.name)}</h2>
            <dl class="detail-list">
              ${Object.entries(mutation.statMultipliers).map(([stat, value]) => `
                <div><dt>${escapeHtml(titleCase(stat))}</dt><dd>${value}x</dd></div>`).join("")}
            </dl>
          </article>`).join("")}
      </section>
    `,
  });
}

function abilitiesPage() {
  const rows = Object.values(abilities).map((ability) => `
    <tr>
      <th>${escapeHtml(ability.name)}</th>
      <td>${escapeHtml(ability.behavior)}</td>
      <td>${escapeHtml(ability.description)}</td>
      <td>${abilityText(ability)}</td>
    </tr>`).join("");

  return layout({
    title: "Abilities",
    description: "Crossover Battlegrounds mana abilities and role-based ability effects.",
    active: "mechanics",
    depth: 1,
    body: `
      <section class="subhero">
        <p class="eyebrow">Combat</p>
        <h1>Abilities</h1>
        <p>Units cast role-driven abilities at 100 mana.</p>
      </section>

      <section class="page-section">
        <div class="table-wrap">
          <table>
            <thead><tr><th>Ability</th><th>Behavior</th><th>Description</th><th>Numbers</th></tr></thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
      </section>
    `,
  });
}

function mapsPage() {
  const worldByMap = Object.fromEntries(story.worlds.map((world) => [world.mapKey, world]));
  return layout({
    title: "Maps",
    description: "Crossover Battlegrounds locations and story world map usage.",
    active: "story",
    depth: 1,
    body: `
      <section class="subhero">
        <p class="eyebrow">Locations</p>
        <h1>Maps</h1>
        <p>Locations used by story worlds.</p>
      </section>

      <section class="page-section map-grid">
        ${maps.map((map) => {
          const world = worldByMap[map.id];
          return `
            <article class="map-card" style="${world?.imageUrl ? `--map-image:url('${world.imageUrl}'); --world-color:${world.color};` : ""}">
              <div class="map-image" aria-hidden="true"></div>
              <p class="eyebrow">${escapeHtml(map.id)}</p>
              <h2>${escapeHtml(map.name)}</h2>
              <dl class="detail-list">
                <div><dt>Story World</dt><dd>${world ? escapeHtml(world.name) : "Not assigned to a story world"}</dd></div>
              </dl>
            </article>`;
        }).join("")}
      </section>
    `,
  });
}

function gettingStartedPage() {
  return layout({
    title: "Start Here",
    description: "Beginner guide for Crossover Battlegrounds covering team roles, story progression, unit placement, infinite mode, and mutations.",
    active: "start",
    depth: 1,
    body: `
      <section class="subhero">
        <p class="eyebrow">Start Here</p>
        <h1>Player Basics</h1>
        <p>Build a squad, place units within the cap, clear waves, and grow through story or infinite runs.</p>
      </section>

      <section class="page-section guide-steps">
        ${[
          ["1", "Build A Mixed Team", "Combine damage dealers with at least one durability or support option. Tanks hold pressure, assassins burst, bruisers keep fighting, buffs raise team damage, healers recover allies, and money farms improve your economy."],
          ["2", "Place Within The Limits", `Each player can place ${placementRules.maxUnitsPerPlayer} units total and up to ${placementRules.maxCopiesPerUnitId} copies of the same unit.`],
          ["3", "Progress Story In Order", "Story acts unlock sequentially. New worlds open after the previous world is fully complete."],
          ["4", "Use Hardcore For Bigger First Clears", `Hardcore applies ${story.hardcore.difficultyMultiplier}x difficulty and ${story.hardcore.rewardMultiplier}x first-clear rewards.`],
          ["5", "Push Infinite Runs", "Infinite mode alternates combat and intermission until allies are defeated, then pays profile money based on wave reached and difficulty."],
        ].map(([num, title, copy]) => `
          <article>
            <span>${num}</span>
            <h2>${escapeHtml(title)}</h2>
            <p>${escapeHtml(copy)}</p>
          </article>`).join("")}
      </section>

      <section class="page-section alt-band">
        <div class="section-heading">
          <p class="eyebrow">First Picks</p>
          <h2>Roster By Role</h2>
        </div>
        <div class="role-grid">
          ${Object.entries(counts.archetypes).map(([role, count]) => `
            <a href="../characters/index.html" class="role-card">
              <strong>${escapeHtml(titleCase(role))}</strong>
              <span>${count} units</span>
            </a>`).join("")}
        </div>
      </section>
    `,
  });
}

function notFoundPage() {
  return layout({
    title: "Page Not Found",
    description: "Crossover Battlegrounds Wiki page not found.",
    active: "",
    body: `
      <section class="subhero">
        <p class="eyebrow">404</p>
        <h1>Page Not Found</h1>
        <p>The page moved or does not exist.</p>
        <a class="primary-link" href="index.html">Return Home</a>
      </section>
    `,
  });
}

const css = `
:root {
  color-scheme: light;
  --ink: #182029;
  --muted: #596674;
  --paper: #fffdf8;
  --surface: #ffffff;
  --surface-2: #f4f7fa;
  --surface-3: #eef6f1;
  --field-bg: #ffffff;
  --header-bg: rgba(255, 253, 248, 0.94);
  --nav-hover: #eef2f6;
  --hero-stat-bg: rgba(255, 255, 255, 0.9);
  --bar-track: #dfe6ec;
  --hover-line: #b8c3cf;
  --footer-bg: #182029;
  --footer-muted: #b6c0cc;
  --line: #d9e0e7;
  --blue: #2f6fdd;
  --green: #20885c;
  --coral: #d85d49;
  --gold: #b98216;
  --violet: #7651b8;
  --shadow: 0 16px 40px rgba(24, 32, 41, 0.12);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-size: 16px;
  letter-spacing: 0;
}

:root[data-theme="dark"] {
  color-scheme: dark;
  --ink: #f2f5f8;
  --muted: #a8b5c3;
  --paper: #0f1419;
  --surface: #171f27;
  --surface-2: #202a34;
  --surface-3: #111a22;
  --field-bg: #101820;
  --header-bg: rgba(15, 20, 25, 0.94);
  --nav-hover: #25313d;
  --hero-stat-bg: rgba(18, 27, 35, 0.92);
  --bar-track: #283441;
  --hover-line: #506171;
  --footer-bg: #080c10;
  --footer-muted: #9aa8b6;
  --line: #2d3946;
  --blue: #69a4ff;
  --green: #50cf91;
  --coral: #ff846f;
  --gold: #efbd56;
  --violet: #a98cf2;
  --shadow: 0 16px 40px rgba(0, 0, 0, 0.36);
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --ink: #f2f5f8;
    --muted: #a8b5c3;
    --paper: #0f1419;
    --surface: #171f27;
    --surface-2: #202a34;
    --surface-3: #111a22;
    --field-bg: #101820;
    --header-bg: rgba(15, 20, 25, 0.94);
    --nav-hover: #25313d;
    --hero-stat-bg: rgba(18, 27, 35, 0.92);
    --bar-track: #283441;
    --hover-line: #506171;
    --footer-bg: #080c10;
    --footer-muted: #9aa8b6;
    --line: #2d3946;
    --blue: #69a4ff;
    --green: #50cf91;
    --coral: #ff846f;
    --gold: #efbd56;
    --violet: #a98cf2;
    --shadow: 0 16px 40px rgba(0, 0, 0, 0.36);
  }
}

* {
  box-sizing: border-box;
}

html {
  scroll-behavior: smooth;
}

body {
  margin: 0;
  color: var(--ink);
  background: var(--paper);
  line-height: 1.55;
  transition: background 160ms ease, color 160ms ease;
}

a {
  color: inherit;
}

img {
  max-width: 100%;
}

.skip-link {
  position: absolute;
  top: -60px;
  left: 16px;
  z-index: 20;
  background: var(--ink);
  color: white;
  padding: 10px 14px;
  border-radius: 6px;
}

.skip-link:focus {
  top: 16px;
}

.site-header {
  position: sticky;
  top: 0;
  z-index: 10;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 24px;
  padding: 14px 28px;
  background: var(--header-bg);
  border-bottom: 1px solid var(--line);
  backdrop-filter: blur(14px);
}

.brand {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  min-width: max-content;
  font-weight: 800;
  text-decoration: none;
}

.brand-mark {
  display: inline-grid;
  place-items: center;
  width: 36px;
  height: 36px;
  border-radius: 8px;
  color: white;
  background: linear-gradient(135deg, var(--blue), var(--coral));
  font-size: 13px;
}

.site-nav {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: flex-end;
  gap: 4px;
}

.header-actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 12px;
}

.site-nav a {
  min-height: 36px;
  padding: 7px 10px;
  border-radius: 6px;
  color: var(--muted);
  font-size: 14px;
  text-decoration: none;
}

.site-nav a:hover,
.site-nav a.active {
  color: var(--ink);
  background: var(--nav-hover);
}

.theme-switch {
  position: relative;
  display: inline-flex;
  align-items: center;
  min-width: 70px;
  height: 36px;
  cursor: pointer;
}

.theme-switch input {
  position: absolute;
  inset: 0;
  opacity: 0;
  cursor: pointer;
}

.theme-switch > span {
  position: relative;
  display: grid;
  grid-template-columns: 1fr 1fr;
  align-items: center;
  width: 70px;
  height: 36px;
  padding: 3px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: var(--surface-2);
  color: var(--muted);
  font-size: 12px;
  font-weight: 900;
  text-align: center;
}

.theme-switch > span::before {
  content: "";
  position: absolute;
  top: 3px;
  left: 3px;
  width: 30px;
  height: 28px;
  border-radius: 999px;
  background: var(--surface);
  box-shadow: 0 2px 8px rgba(24, 32, 41, 0.18);
  transition: transform 160ms ease;
}

.theme-switch input:checked + span::before {
  transform: translateX(34px);
}

.theme-switch span span {
  position: relative;
  z-index: 1;
}

.theme-switch input:focus-visible + span {
  outline: 2px solid var(--blue);
  outline-offset: 2px;
}

main {
  min-height: 70vh;
}

.hero {
  min-height: 520px;
  display: grid;
  align-items: end;
  padding: 92px 28px 44px;
  color: white;
  background:
    linear-gradient(90deg, rgba(18, 26, 35, 0.90), rgba(18, 26, 35, 0.56), rgba(18, 26, 35, 0.25)),
    var(--hero-image),
    linear-gradient(135deg, #26394d, #486a5d);
  background-size: cover;
  background-position: center;
}

.hero-content {
  width: min(100%, 1020px);
  margin: 0 auto;
}

.eyebrow {
  margin: 0 0 8px;
  color: var(--coral);
  font-size: 13px;
  font-weight: 800;
  text-transform: uppercase;
}

.hero .eyebrow {
  color: #ffd15f;
}

h1,
h2,
h3,
p {
  overflow-wrap: anywhere;
}

h1,
h2,
h3 {
  margin: 0;
  line-height: 1.1;
}

h1 {
  max-width: 920px;
  font-size: 56px;
}

h2 {
  font-size: 30px;
}

h3 {
  font-size: 18px;
}

.hero-copy,
.subhero p {
  max-width: 720px;
  color: inherit;
  font-size: 19px;
}

.hero-actions,
.footer-links {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
}

.primary-link,
.secondary-link {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 44px;
  padding: 10px 16px;
  border-radius: 8px;
  font-weight: 800;
  text-decoration: none;
}

.primary-link {
  color: white;
  background: var(--coral);
}

.secondary-link {
  color: var(--ink);
  background: var(--surface);
}

.summary-strip {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 1px;
  width: min(1120px, calc(100% - 32px));
  margin: -28px auto 0;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--line);
  box-shadow: var(--shadow);
}

.summary-strip.local {
  margin-top: 28px;
  box-shadow: none;
}

.summary-strip div {
  min-height: 92px;
  display: grid;
  place-items: center;
  background: var(--surface);
  text-align: center;
}

.summary-strip strong {
  display: block;
  font-size: 30px;
}

.summary-strip span {
  color: var(--muted);
  font-size: 14px;
}

.page-section,
.subhero {
  width: min(1180px, calc(100% - 32px));
  margin: 0 auto;
  padding: 56px 0;
}

.subhero {
  padding-top: 66px;
}

.subhero h1 {
  font-size: 46px;
}

.section-heading {
  display: flex;
  align-items: end;
  justify-content: space-between;
  gap: 18px;
  margin-bottom: 22px;
}

.alt-band {
  width: 100%;
  padding-inline: max(16px, calc((100% - 1180px) / 2));
  background: var(--surface-3);
}

.link-grid,
.unit-grid,
.map-grid,
.mutation-grid,
.mechanics-grid,
.glossary-grid,
.role-grid,
.guide-steps {
  display: grid;
  gap: 16px;
}

.link-grid {
  grid-template-columns: repeat(3, 1fr);
}

.feature-link,
.unit-card,
.info-panel,
.mutation-card,
.map-card,
.glossary-grid article,
.guide-steps article,
.role-card {
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
}

.feature-link,
.role-card {
  display: block;
  padding: 20px;
  text-decoration: none;
}

.feature-link span,
.role-card strong {
  font-size: 20px;
  font-weight: 800;
}

.feature-link p,
.unit-card p,
.info-panel p,
.map-card p,
.glossary-grid p,
.guide-steps p {
  color: var(--muted);
}

.unit-grid {
  grid-template-columns: repeat(4, 1fr);
}

.unit-grid.compact {
  grid-template-columns: repeat(4, 1fr);
}

.unit-card {
  position: relative;
  display: flex;
  min-height: 246px;
  flex-direction: column;
  gap: 10px;
  padding: 16px;
  color: inherit;
  text-decoration: none;
  transition: transform 160ms ease, box-shadow 160ms ease, border-color 160ms ease;
}

.unit-card:hover {
  transform: translateY(-2px);
  border-color: var(--hover-line);
  box-shadow: 0 10px 24px rgba(24, 32, 41, 0.10);
}

.unit-card[hidden] {
  display: none;
}

.avatar {
  display: inline-grid;
  place-items: center;
  width: 54px;
  height: 54px;
  border-radius: 8px;
  color: white;
  background: linear-gradient(135deg, var(--blue), var(--green));
  font-weight: 900;
}

.avatar.large {
  width: 96px;
  height: 96px;
  font-size: 28px;
}

.star-1 .avatar,
.star-1.character-hero {
  background-image: linear-gradient(135deg, #6d747c, #b9c0c7);
}

.star-2 .avatar,
.star-2.character-hero {
  background-image: linear-gradient(135deg, #1e8c5e, #77cf78);
}

.star-3 .avatar,
.star-3.character-hero {
  background-image: linear-gradient(135deg, #2368cc, #75b7ff);
}

.star-4 .avatar,
.star-4.character-hero {
  background-image: linear-gradient(135deg, #744ac5, #d85d49);
}

.unit-meta,
.ability-line,
.small-note {
  color: var(--muted);
  font-size: 13px;
}

.stars {
  color: var(--gold);
  white-space: nowrap;
}

.mini-stats {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 6px;
  margin: auto 0 0;
}

.mini-stats div,
.hero-stats div,
.detail-list div {
  padding: 10px;
  border-radius: 6px;
  background: var(--surface-2);
}

dt {
  color: var(--muted);
  font-size: 12px;
  font-weight: 700;
}

dd {
  margin: 0;
  font-weight: 800;
}

.tools-panel {
  display: grid;
  grid-template-columns: minmax(220px, 1fr) repeat(3, 160px) 120px;
  gap: 12px;
  width: min(1180px, calc(100% - 32px));
  margin: 0 auto;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
}

.tools-panel label {
  display: grid;
  gap: 6px;
  color: var(--muted);
  font-size: 13px;
  font-weight: 800;
}

input:not([type="checkbox"]),
select {
  width: 100%;
  min-height: 42px;
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 8px 10px;
  color: var(--ink);
  background: var(--field-bg);
  font: inherit;
}

.result-count {
  align-self: end;
  min-height: 42px;
  display: grid;
  place-items: center;
  border-radius: 6px;
  color: var(--muted);
  background: var(--surface-2);
  font-size: 13px;
  font-weight: 800;
}

.character-hero {
  width: min(1180px, calc(100% - 32px));
  margin: 36px auto 0;
  padding: 26px;
  border-radius: 8px;
  color: white;
}

.character-title {
  display: flex;
  align-items: center;
  gap: 20px;
}

.character-title p {
  max-width: 760px;
}

.breadcrumb {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-bottom: 18px;
  font-size: 14px;
}

.breadcrumb a {
  color: white;
  font-weight: 800;
}

.hero-stats {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 10px;
  margin: 24px 0 0;
}

.hero-stats div {
  color: var(--ink);
  background: var(--hero-stat-bg);
}

.two-column {
  display: grid;
  grid-template-columns: minmax(0, 1.25fr) minmax(280px, 0.75fr);
  gap: 20px;
}

.info-panel,
.mutation-card,
.map-card,
.glossary-grid article,
.guide-steps article {
  padding: 20px;
}

.stat-bars {
  display: grid;
  gap: 12px;
}

.bar-row {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 8px 14px;
  align-items: center;
}

.bar-track {
  grid-column: 1 / -1;
  height: 10px;
  overflow: hidden;
  border-radius: 4px;
  background: var(--bar-track);
}

.bar-track span {
  display: block;
  height: 100%;
  border-radius: 4px;
  background: linear-gradient(90deg, var(--green), var(--blue), var(--coral));
}

.detail-list {
  display: grid;
  gap: 8px;
  margin: 18px 0 0;
}

.table-wrap {
  overflow-x: auto;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--surface);
}

table {
  width: 100%;
  min-width: 760px;
  border-collapse: collapse;
}

th,
td {
  padding: 13px 14px;
  border-bottom: 1px solid var(--line);
  text-align: left;
  vertical-align: top;
}

thead th {
  color: var(--muted);
  background: var(--surface-2);
  font-size: 13px;
}

tbody tr:last-child th,
tbody tr:last-child td {
  border-bottom: 0;
}

.reward-cell span {
  display: inline-block;
  margin: 0 5px 5px 0;
  padding: 3px 7px;
  border-radius: 6px;
  background: var(--surface-2);
  font-size: 13px;
  font-weight: 700;
}

.world-section {
  width: min(1180px, calc(100% - 32px));
  margin: 32px auto;
}

.world-heading {
  min-height: 190px;
  display: flex;
  align-items: end;
  margin-bottom: 14px;
  padding: 22px;
  border-radius: 8px;
  color: white;
  background:
    linear-gradient(90deg, rgba(24, 32, 41, 0.86), rgba(24, 32, 41, 0.32)),
    var(--world-image),
    var(--world-color);
  background-size: cover;
  background-position: center;
}

.mechanics-grid {
  grid-template-columns: repeat(2, 1fr);
}

.clean-list {
  margin: 14px 0 0;
  padding-left: 20px;
}

.glossary-grid {
  grid-template-columns: repeat(3, 1fr);
}

.mutation-grid {
  grid-template-columns: repeat(3, 1fr);
}

.mutation-swatch {
  height: 84px;
  margin-bottom: 18px;
  border-radius: 8px;
  background: linear-gradient(115deg, var(--mutation-gradient));
}

.map-grid {
  grid-template-columns: repeat(3, 1fr);
}

.map-image {
  height: 168px;
  margin: -20px -20px 18px;
  border-radius: 8px 8px 0 0;
  background:
    linear-gradient(180deg, rgba(24, 32, 41, 0.08), rgba(24, 32, 41, 0.38)),
    var(--map-image),
    linear-gradient(135deg, var(--world-color, #536a82), #d85d49);
  background-size: cover;
  background-position: center;
}

.guide-steps {
  grid-template-columns: repeat(5, 1fr);
}

.guide-steps article span {
  display: inline-grid;
  place-items: center;
  width: 34px;
  height: 34px;
  margin-bottom: 14px;
  border-radius: 8px;
  color: white;
  background: var(--blue);
  font-weight: 900;
}

.role-grid {
  grid-template-columns: repeat(6, 1fr);
}

.role-card span {
  display: block;
  color: var(--muted);
}

.site-footer {
  display: flex;
  justify-content: space-between;
  gap: 24px;
  padding: 28px;
  border-top: 1px solid var(--line);
  background: var(--footer-bg);
  color: white;
}

.site-footer span {
  display: block;
  color: var(--footer-muted);
}

.footer-links a {
  color: white;
}

@media (max-width: 980px) {
  .site-header {
    align-items: flex-start;
    flex-direction: column;
  }

  h1 {
    font-size: 42px;
  }

  .summary-strip,
  .hero-stats,
  .link-grid,
  .unit-grid,
  .unit-grid.compact,
  .mechanics-grid,
  .glossary-grid,
  .mutation-grid,
  .map-grid,
  .guide-steps,
  .role-grid {
    grid-template-columns: repeat(2, 1fr);
  }

  .tools-panel,
  .two-column {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 620px) {
  .site-header,
  .hero,
  .site-footer {
    padding-inline: 16px;
  }

  .site-nav {
    justify-content: flex-start;
  }

  .hero {
    min-height: 500px;
  }

  h1,
  .subhero h1 {
    font-size: 34px;
  }

  h2 {
    font-size: 24px;
  }

  .summary-strip,
  .hero-stats,
  .link-grid,
  .unit-grid,
  .unit-grid.compact,
  .mechanics-grid,
  .glossary-grid,
  .mutation-grid,
  .map-grid,
  .guide-steps,
  .role-grid {
    grid-template-columns: 1fr;
  }

  .character-title {
    align-items: flex-start;
    flex-direction: column;
  }

  .site-footer {
    flex-direction: column;
  }
}
`;

const js = `
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
`;

const favicon = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="12" fill="#182029"/>
  <path d="M14 34c0-11 8-20 19-20 6 0 11 2 15 6l-8 8c-2-2-4-3-7-3-5 0-9 4-9 9s4 9 9 9c3 0 6-1 8-4l8 8c-4 4-9 7-16 7-11 0-19-9-19-20z" fill="#fffdf8"/>
  <path d="M39 12h11v40H39z" fill="#d85d49"/>
</svg>
`;

const publicCharacters = roster.map(({ id, modelName, ...unit }) => unit);
const publicMaps = maps.map(({ modelName, ...map }) => map);
const publicStory = {
  ...story,
  worlds: story.worlds.map((world) => ({
    ...world,
    acts: world.acts.map((act) => {
      const { unitId, modelScale, ...boss } = act.boss ?? {};
      return { ...act, boss };
    }),
  })),
};

const dataJson = JSON.stringify({
  generatedFrom: "GameModule.lua",
  counts,
  characters: publicCharacters,
  story: publicStory,
  maps: publicMaps,
  mutations,
  abilities,
}, null, 2);

writePage("assets/styles.css", css.trimStart());
writePage("assets/site.js", js.trimStart());
writePage("assets/favicon.svg", favicon.trimStart());
writePage("data/wiki-data.json", `${dataJson}\n`);
writePage(".nojekyll", "");

writePage("index.html", homePage());
writePage("getting-started/index.html", gettingStartedPage());
writePage("characters/index.html", charactersIndexPage());
for (const unit of roster) {
  writePage(`characters/${unit.id}/index.html`, characterPage(unit));
}
writePage("story/index.html", storyPage());
writePage("mechanics/index.html", mechanicsPage());
writePage("mutations/index.html", mutationsPage());
writePage("abilities/index.html", abilitiesPage());
writePage("maps/index.html", mapsPage());
writePage("404.html", notFoundPage());

console.log(`Generated ${roster.length} character pages and ${story.worlds.length} story worlds.`);
