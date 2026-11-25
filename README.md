# Salvager

A WoW Forever addon for disenchant trading. It does three things:

1. Prices the disenchanting materials (dust, essences, shards) at the auction house.
2. Finds gear that costs less than its expected disenchant value, with the profit in gold for each auction, and buys it with one click.
3. Follows your cost from the purchase to the disenchant to the sale, and shows a break-even price for each material.

## Install

Copy the `Salvager` folder into `World of Warcraft/_forever_/Interface/AddOns/`, then `/reload`.

## Use

1. Open the auction house. The Salvager window opens with it (also: minimap button or `/salv`).
2. Click **Scan both**: material prices first (about 20 seconds), then the gear.
3. Click ▶ (play) to scan the gear again every 20 seconds; it turns into pause. ■ (stop) ends it.
4. **Deals** lists every auction below the buy limit, best profit first. Click **Buy**.
5. Take your "Auction won" mail, disenchant, and sell the materials as usual. Salvager books each step.
6. **Materials** shows price, stock, average cost and break-even. **Post** sells what is in your bags at
   1 copper under the lowest listing; a warning sign shows when that is below your break-even.
   **Pop out** moves the materials list to a window of its own; close it to put the list back.
   **Limits** shows the buy limit per item level band for armor and weapons.
   **Ledger** opens a window of its own: what you bought with what each item was disenchanted into,
   your sales with their profit, and your disenchant odds. **Log** opens the activity log.
7. Options: Esc > Options > AddOns > Salvager, the **Options** button, or right-click the minimap button.

## How the value is calculated

For an item: the chance of each material × its average quantity × its price, plus the Arcane Salvager bonus
when you can use it, minus the 5% auction house cut. The buy limit is that value minus your minimum profit.

- The table is Classic's disenchant table by item level (`Salvager/Data.lua`).
- Arcane Salvager: a 50% chance of one extra dust or essence (community data, not official). It is
  included only when you know the recipe or have the item, or when you set `/salv salvager on`.
- Material price: the average of the cheapest 20 units listed (your own listings left out).

## Cost tracking

- Purchases come from the "Auction won" mail (any addon or window), oldest first per item.
- On disenchant, the item's cost is split across the materials by their value at that moment.
- Each material keeps an average cost. Break-even = average cost ÷ 0.95.
- Sales come from the "Auction successful" mail.
- Materials you had before: `/salv stock <item> <quantity> <cost each>`.

## Commands

`/salv` opens the window. `/salv help` lists the rest.

## Development

`make check` runs the tests and lint in Docker (Lua 5.1, busted, luacheck). `make install` copies the
addon to the gaming PC.
