# Salvager

<img src="docs/logo.png" alt="Salvager logo" width="128">

A WoW Forever addon for disenchant trading. It does three things:

1. Prices the disenchanting materials (dust, essences, shards) at the auction house.
2. Finds gear that costs less than its expected disenchant value, with the profit in gold for each auction, and buys it with one click.
3. Follows your cost from the purchase to the disenchant to the sale, and shows a break-even price for each material.

## Install

With the CurseForge app: pick the WoW Forever game version and search for Salvager.

By hand: copy the `Salvager` folder from the zip into `World of Warcraft/_forever_/Interface/AddOns/`, then
`/reload`.

## Use

1. Open the auction house. The Salvager window opens with it (also: minimap button or `/salv`).
2. Under **Scan once**, click **Both**: material prices first (about 20 seconds), then the gear.
3. Click ▶ (play) to scan the gear again every 20 seconds; it turns into pause. ■ (stop) ends it.
4. **Gear** lists every auction of gear below its buy limit, best profit first. Click **Buy**, or **Buy Top**
   (bottom right) to buy the best single auction in the list by the current sort (profit or return), whatever
   row it is in. The gear it will buy is shown above the button (point at it for its numbers); each click buys
   the next best one. Click an auction's row for its **Gear details**: how its Expected value is made (one line
   per material), its buy limit and what sets it, your history with this gear and its band, the other auctions
   of it, and a Buy button. A row with x3 is a group of auctions: click it to open or close it.
5. Take your "Auction won" mail, disenchant, and sell the materials as usual. Salvager books each step.
6. **Materials** shows price, stock, average cost and break-even. **Post** sells what is in your bags at
   1 copper under the lowest listing; a warning sign shows when that is below your break-even.
   **Pop out** moves the materials list to a window of its own; close it to put the list back.
   **Limits** shows the buy limit per item level band for armor and weapons.
   The ⋮ button at the right end of a table's titles chooses the columns it shows.
   **Ledger** opens a window of its own: all gear you bought by day, with what each piece was disenchanted into,
   what you bought and have not picked up from the mail yet (with your free bag space), your current batch (what
   you picked up and have not disenchanted or posted yet, with what it cost, was expected to make and has made),
   your auctions (listed, sold and waiting for the money, undercut) and the sales already paid with their
   profit, and the disenchant odds of every band with its buy limit and the chance to lose at that limit.
   Point at a column title for what it means. **Log** opens the activity log.
   **Reports** shows what your trading made, for this session (login to logout, a /reload keeps it), a past
   session or the last hours or days: sales, the cost of what you sold, the change in your stock and how much
   richer you are, then a check against your gold. It also lists every change of your gold; Gear shows the
   profit by band (Bands) and piece by piece (History); Materials what each material gave and sold for.
   A heading of a grouped table (gear type, quality) opens and closes with a click; it stays as you left it.
7. Options: Esc > Options > AddOns > Salvager, the **Options** button, or right-click the minimap button.

## How the value is calculated

For a piece of gear: the chance of each material × its average quantity × its price, plus the Arcane Salvager bonus
when you can use it, minus the 5% auction house cut. The buy limit is that value minus your minimum profit.

- The table is Classic's disenchant table by item level (`Salvager/Data.lua`). Your own disenchants move it: per
  band, the table counts as 50 disenchants and yours are added to it, so a band with few of yours stays near the
  table and a band with hundreds follows your results (Ledger, Odds: Rate used).
- Each material counts at its price × what your sales of it really got against the price, less the deposits you
  lose per unit sold.
- Time to sell (Materials list): how long your posts of a material took to sell. A deal's tooltip shows its Return
  per day (Return ÷ the days until its materials sell, at least one day).
- Arcane Salvager: a 50% chance of one extra dust or essence (community data, not official). It is
  included only when you know the recipe or have the Salvager, or when you set `/salv salvager on`.
- Material price: the average of the cheapest 20 units listed (your own listings left out).

## Cost tracking

- Purchases come from the "Auction won" mail (any addon or window), oldest first per piece of gear.
- On disenchant, the gear's cost goes into its band: each band's cost is shared over its unsold materials by
  their value at the disenchants.
- Each material keeps an average cost. Break-even = average cost ÷ 0.95.
- Sales come from the "Auction successful" mail.
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
   `CURSEFORGE_PROJECT_ID`, `RELEASE_TYPE`), with the commit subjects since the last release as the
   changelog, tags `v<version>` and pushes the tag to GitHub. The working tree must be committed.

## License

MIT, see `LICENSE`.
