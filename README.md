# Crossover Project (Roblox)

## GitHub Pages Wiki

This repo now includes a generated, player-facing static wiki for **Crossover Battlegrounds**.

Main entry points:

- `index.html`: wiki home page
- `characters/index.html`: searchable character roster
- `characters/<unit-id>/index.html`: individual character pages
- `getting-started/index.html`: player basics
- `story/index.html`: story worlds, acts, rewards, and bosses
- `mechanics/index.html`: placement, infinite mode, rewards, and combat rules
- `mutations/index.html`: mutation chances and stat multipliers
- `abilities/index.html`: mana ability reference
- `maps/index.html`: map registry and story map usage

The site is built for GitHub Pages from the repository root. In GitHub, set **Pages** to deploy from your chosen branch and the root folder (`/`).

Regenerate the wiki after changing `GameModule.lua`:

```sh
npm run build
npm run validate
```

The generated pages are checked in so GitHub Pages does not need Node or a build step.

This repo is a **script source mirror** for a Roblox experience that uses a **runtime-loaded package** (a published Model) to share all scripts/UI across multiple places (Lobby / Infinite / Story).

## How the runtime package works

Each thin place contains only a small server Script: `[ServerScriptService/RuntimeBootstrap.lua](ServerScriptService/RuntimeBootstrap.lua)`.

At server start it:

- Loads your published **package asset** (group-owned Model) via `InsertService:LoadAsset(assetId)`
- Finds `CrossoverPackage/Bundles/...` in that asset
- Clones the bundle contents into the live services:
  - `ReplicatedStorage`
  - `ServerScriptService`
  - `ServerStorage`
  - `StarterGui`
  - `StarterPlayer`
- Publishes two attributes used by UI logic:
  - `ReplicatedStorage.RuntimePlaceRole`
  - `ReplicatedStorage.RuntimeUiMode`
- Optionally loads a map model via `GameModule.Maps[mapKey]` (if configured)
- Optionally runs `ServerScriptService.ServerEntry` if present

## Package asset structure (published Model)

Your published Model should look like:

- `CrossoverPackage` (Model)
  - `Bundles` (Folder)
    - `Shared`
      - `ReplicatedStorage` (Folder)
      - `ServerScriptService` (Folder)
      - `ServerStorage` (Folder)
      - `StarterGui` (Folder)
      - `StarterPlayer` (Folder)
    - `Lobby` (same service folders)
    - `Combat` (same service folders)
    - `Infinite` (same service folders)
    - `Story` (same service folders)

**Rule of thumb**

- Put anything used everywhere in **Shared**
- Put lobby UI/teleports in **Lobby**
- Put wave/combat servers and combat HUD in **Combat**
- Put Infinite/Story specifics in their respective bundles

## Thin place configuration

Edit the `settings` table at the top of `[RuntimeBootstrap.lua](ServerScriptService/RuntimeBootstrap.lua)`:

- `**primaryAssetId`**: asset id of the published `CrossoverPackage` Model
- `**placeRole**`: `"Lobby"`, `"Infinite"`, `"Story"`, or `"Gameplay"`
- `**uiMode**`: `"Lobby"` or `"Gameplay"`
- `**mapKey**` / `**mapAssetId**`: optional map selection

## Infinite mode

Set `**Workspace.GameInfo.mode**` (StringValue) to `**infinite**` on the map/place.

Flow:

1. **Pregame** — 90s countdown (`InfinitePhase = "pregame"`, `PhaseTimeLeft` counts down). Players can place units.
2. **Combat** — first wave spawns, then `StartRound` runs. Same PvE combat as normal until allies or enemies are wiped.
3. **Wave clear** — session money bonus (same formula as classic PvE), then **intermission** (30s or until all players vote via `InfiniteAdvanceVote`).
4. **Next wave** — `SummonWave` + `StartRound` again.
5. **Allies wiped** — run ends; each player receives **DataStore** `player_money` via `PlayerProfile.AddPlayerMoney` (scales with **wave reached** and **difficulty**). `InfinitePhase = "defeat"`.

**UI** (under `StarterGui` → `HeroGUI` → `gameInfo`): LocalScript `[InfiniteGameInfo.lua](CrossoverPackage/Bundles/Shared/StarterGui/HeroGUI/InfiniteGameInfo.lua)` shows difficulty, wave, timer, and `ADVANCE? (votes/needed)` when `InfinitePhase` is `pregame` or `intermission`.

**Scripts**: `[InfiniteMode.lua](CrossoverPackage/Bundles/Shared/ServerScriptService/InfiniteMode.lua)` + `[InfiniteModeBootstrap.lua](CrossoverPackage/Bundles/Shared/ServerScriptService/InfiniteModeBootstrap.lua)`. `[GameHandler.lua](CrossoverPackage/Bundles/Shared/ServerScriptService/GameHandler.lua)` skips its default `SummonWave(1,1)` when mode is infinite.

**Enemy scaling (co-op)**: `[WaveServer.lua](CrossoverPackage/Bundles/Shared/ServerScriptService/WaveServer.lua)` scales **spawn count only** (sublinear `1 + 0.5×(n−1)` for `n` players). Enemy **HP / damage / attack speed** match solo for the same wave and difficulty.

## Maps

`[ReplicatedStorage/GameModule.lua](ReplicatedStorage/GameModule.lua)` contains gameplay data and also includes:

- `GameModule.Maps`: map metadata registry (keys → `{ assetId = ..., displayName = ..., ... }`)

The runtime bootstrap can load maps by `mapKey` (recommended) so places stay lightweight.

## Known pitfall: doubled server behavior

If you keep the inserted package under `ServerScriptService` for debugging, any Scripts inside it can **execute twice**.

`RuntimeBootstrap.lua` avoids this by default; debug copies (when enabled) are stored under **ServerStorage**.
