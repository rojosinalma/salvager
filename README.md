# Salvager

<img src="docs/logo.png" alt="Salvager logo" width="128">

A WoW Forever addon for disenchant trading. It does three things:

1. Prices the disenchanting materials (dust, essences, shards) at the auction house.
2. Finds gear that costs less than its average disenchant value, with the profit in gold for each auction (pessimistic,
   average and optimistic: one disenchant gives whole units of one material), and buys it with one click.
3. Follows your cost from the purchase to the disenchant to the sale, and shows a break-even price for each material.

## What's new in 0.4

1. The forecast learns from your own disenchants. Each band starts from the game's table and moves toward what you
   actually got; the Arcane Salvager bonus is learned per material (dust, essence, shard) from all your bands
   together, so a band you rarely disenchant still gets a realistic bonus. On my own data the Salvager's extra dust
   comes about a third of the time, not the quarter the usual "50% chance of +1" gives.
2. Recent results count more: a result from today counts 1, one from a month ago 0.5. If the game changes, the
   numbers follow within a few weeks. Nothing is deleted. Sell price ratio and time to sell work the same way.
3. You can see how much the numbers rest on: each Odds card shows its weighted results, with "few results" when
   they are thin; the card's "?" explains the learning and shows the Salvager shape the band uses.
4. Profit as a range from whole units (pessimistic, average, optimistic), every average labelled as one, and an
   orange highlight on unusually high returns (0.3.152).

## Install

With the CurseForge app: pick the WoW Forever game version and search for Salvager.

By hand: copy the `Salvager` folder from the zip into `World of Warcraft/_forever_/Interface/AddOns/`, then
`/reload`.

## Use

1. Open the auction house. The Salvager window opens with it (also: minimap button or `/salv`). The other windows
   open from the mini panel, always on: one button for each Salvager window, in two columns (Shift + click the
   minimap button, or its X, to hide or show it). The **_** button in the main window's title bar minimizes it; the
   gear icon next to it opens the options.
2. Under **Scan once**, click **Both**: material prices first (about 20 seconds), then the gear.
3. Click ▶ (play) to scan the gear live; it turns into ■ (stop), which ends it. Each short round looks at the
   cheapest listings of a few qualities, gear types and item level bands, searches only the gear that changed, and
   makes the top three deals current again; then it rests (8 seconds, Options), so the auction house is free when
   you click Buy. The status at the bottom says "Live: 18 targets, round 2.1 s, next in 6 s". If the auction house
   does not sort the listings by price, Play scans full rounds (every page, every 20 seconds) for the rest of the
   session, and the status says so.
   Tick **Arcane Salvager** in the Scan settings when you disenchant near the Arcane Salvager: the gear is then
   valued with its bonus.
4. **Gear** lists every auction of gear below its buy limit, best average profit first. Its profit shows as
   "low - avg - high": the pessimistic outcome (9 in 10 disenchants give this or more), the average over many
   pieces and the optimistic outcome (1 in 10 gives this or more); point at it for every outcome of one
   disenchant with its chance. A grey "?" after the optimistic one: that outcome is not proven on Forever. An
   orange row with "!" after its buyout has an unusually high average return (50% or more, Options): check it
   before you buy. Click **Buy**, or **Buy Top**
   (bottom right) to buy the best single auction in the list by the current sort (average profit or return),
   whatever row it is in. The gear it will buy is shown above the button (point at it for its numbers); each click
   buys the next best one. Click an auction's row for its **Gear details**: every outcome of one disenchant (whole
   units, the pessimistic and optimistic ones marked, the average last), its buy limit and what sets it, your
   history with this gear and its band, the other auctions of it, and a Buy button. A row with x3 is a group of
   auctions: click it to open or close it.
5. Take your "Auction won" mail, disenchant, and sell the materials as usual. Salvager books each step.
   The **Disenchant** panel opens by itself when gear you bought lands in your bags: each click on its Disenchant
   button disenchants the next piece (only gear you bought with Salvager, never your own). Bind a key to it in Key
   Bindings, AddOns, Salvager, "Disenchant next piece": each press is one cast. Below, what each disenchant gave.
      Also from the mini panel or `/salv disenchant`.
   Two macros are made at the first login: **Salvager Buy** (clicks Buy Top) and **Salvager DE** (clicks the
   Disenchant button). Drag them from `/macro` to your bars or bind them to keys; Options, "Create the macros again",
   makes a deleted one again.
6. **Materials** shows price, stock, average cost and break-even. **Post** sells what is in your bags at
   1 copper under the lowest listing; a warning sign shows when that is below your break-even.
   **Pop out** moves the materials list to a window of its own; close it to put the list back.
   **Limits** shows the buy limit per item level band for armor and weapons.
      A click on a column's title sorts the table by it (again: the other way round).
   The ⋮ button at the right end of a table's titles chooses the columns it shows. Where a window has two tables,
   drag the bar between them to make one taller (right-click: back to the default).
   **Ledger** opens a window of its own: all gear you bought by day, with what each piece was disenchanted into,
   what waits in the mail (Mail, with your free bag space), what is pending (Pending: what
   you bought and have not disenchanted or posted yet, in the mail or picked up, with what it cost, its average value
   and what it has made),
   your auctions (listed, sold and waiting for the money, undercut; ▶ next to Check undercuts checks them every
   minute while the auction house is open), who undercuts you (Competition: each seller under your price, how
   often, on which materials, by how much, and what it cost you) and the sales already paid with their
   profit, and how close the forecasts came (Accuracy).
   Point at a column title for what it means. **Log** opens the activity log.
   **Reports** shows what your trading made, for this session (login to logout, a /reload keeps it), a past
   session or the last hours or days: sales, the cost of what you sold, the change in your stock and how much
   richer you are, then a check against your gold. It also lists every change of your gold; Gear shows the
   profit by band (Bands) and piece by piece (History); Materials what each material gave and sold for;
   Competition who undercut you in the period, what it cost you and how you answered, per competitor and material;
   Odds the game's disenchant table of every band against your own disenchants (tick "Show with and without the
   Salvager" for the dust and essence with its bonus apart), with the chance to lose at the buy limit; point at a
   band's "?" for its value, buy limit and prices. The button at the right of its filters pops it out.
   A heading of a grouped table (gear type, quality) opens and closes with a click; it stays as you left it.
   **Search** (first on the filter row of Reports, Charts and the Ledger's Purchases) shows the rows whose name has
   the text you type; the X in the box or Escape clears it. Every list of materials is in the Materials window's
   order: dust, essences, shards, each from the lowest level up.
7. Options: Esc > Options > AddOns > Salvager, the **Options** button, or right-click the minimap button.
   **Times shown in** picks the clock of every time and day the addon shows: your computer's (local time) or
   the realm's (server time).

## How the value is calculated

One disenchant gives whole units of one material: 1, 2 or 3 Soul Dust, never 1.5. For a piece of gear the addon
lists every such outcome with its chance and its value (units × price, minus the 5% auction house cut), with the
Arcane Salvager bonus when you can use it. The Gear list shows three of them as profit: the pessimistic outcome (9 in
10 disenchants give this or more), the average over many pieces (chance × value, added up; no single disenchant
gives it) and the optimistic outcome (1 in 10 gives this or more). The buy limit is the average minus your minimum
profit; where the band's rule is not measured on Forever (Epic item level 56 and up), the pessimistic value minus
your minimum profit.

- The table is Classic's disenchant table by item level (`Salvager/Data.lua`). Your own disenchants move it: per
  band, the table counts as 50 disenchants and yours are added to it, so a band with few of yours stays near the
  table and a band with hundreds follows your results (Reports, Odds: a band's "?", Rates used from). A band rests
  on your results (observed) from 50 of yours, else on the table (documented), or on Classic's rule not measured on
  Forever (inferred: Epic 56+).
- Each result counts 0.5^(its age in days / 30): today 1, a month ago 0.5. The counts shown as "weighted" are these
  weights added up.
- Each material counts at its price × what your sales of it really got against the price, less the deposits you
  lose per unit sold.
- Time to sell (Materials list): how long your posts of a material took to sell. A deal's tooltip shows its average
  return per day (Avg return ÷ the days until its materials sell, at least one day).
- Arcane Salvager: how often it gives one more unit is learned per material kind from all your disenchants with
  it, starting from the community figure (a 50% chance of one extra dust or essence, never on shards) as if it were
  50 results; Options, "Starting chance of one extra dust or essence (%)", sets that start. It is included in the
  buy prices while the main window's **Arcane Salvager** box is ticked (`/salv salvager on|off`).
- Material price: the average of the cheapest 20 units listed (your own listings left out).

## Cost tracking

- Purchases are booked when Salvager's Buy goes through, and from the "Auction won" mail (any addon or window),
  oldest first per piece of gear.
- On disenchant, the gear's cost goes into its band: each band's cost is shared over its unsold materials by
  their value at the disenchants.
- Each material keeps an average cost. Break-even = average cost ÷ 0.95.
- Sales are booked when your auctions list shows them sold; the "Auction successful" mail marks them paid (and
  books a sale the list did not show).
- Materials you had before: `/salv stock <material> <quantity> <cost each>`.

## Commands

`/salv` opens the window. `/salv help` lists the rest.

Windows can be dragged partly off the screen, until 40 px of their title bar are left. `/salv windows reset`
brings every Salvager window back on the screen, at its default place.

## Development

`make check` runs the tests and lint in Docker (Lua 5.1, busted, luacheck). The other targets read local
settings from `.env` (copy `.env.example`):

1. `make install` copies the addon to a Windows PC over SSH (`INSTALL_HOST`, `ADDONS_DIR`).
2. `make layout` copies the saved variables from that PC and draws each Salvager window that was open at the last
   `/reload` as a PNG in `.agents/tmp/layout/`, with a list of layout problems (Docker for the PNG).
3. `make package` builds `dist/Salvager-<version>.zip`.
4. `make release` uploads that zip to CurseForge as the TOC's version (`CURSEFORGE_TOKEN`,
   `CURSEFORGE_PROJECT_ID`, `RELEASE_TYPE`), with the version's section of `CHANGELOG.md` as the changelog (else
   the commit subjects since the last release), tags `v<version>` and pushes the tag to GitHub. The working tree
   must be committed.

## License

MIT, see `LICENSE`.
