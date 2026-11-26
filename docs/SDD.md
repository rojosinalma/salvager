# Salvager — design decisions

## Scope

Public WoW Forever addon (interface 16001), on CurseForge under the MIT license (89). Buying and selling at the auction house only; vendor
flipping is out of scope for now.

## Decisions

1. **Disenchant table by item level** (Classic table). Required level is only a rough guide; the auction
   house's level filter uses required level, but every item key carries its item level, which picks the band.
2. **Arcane Salvager rule:** 50% chance of one extra dust or essence; never on shards or single fixed
   results. Source: a community spreadsheet with 7000+ disenchants. Configurable (`salvagerChance`).
   Applied to buy prices only when the player can use it (recipe spell 1263056 or item 279985), or by
   `/salv salvager on|off`.
3. **Material price and what a unit sells for** (rewritten 0.3.122, the user, 2026-11-26). The material's price
   (its value) = average unit price of the cheapest 20 units, own listings excluded. When a scan finds none, the
   last price stays in use (marked `*`) for one day at most (67). A missing essence price is filled from the other
   form (3 lesser = 1 greater, marked `~`). The price itself stays the market's; what the forecast counts a unit at
   is price × the material's **sell price ratio** (`ns.SellRatio`, `Ledger.SellRatios`): what one unit of it
   really sold for (the sale price each, before the cut) against its price when that auction was posted. Per
   material, the median of its sales of the last 30 days, weighted by units (`Model.WeightedMedian`); under 5 sales
   it is pulled toward the median of all materials, (n × own + (5 − n) × all) ÷ 5 (`Model.Blend`), and the median
   of all toward 1 the same way; no sales at all = 1. The price at the post is recorded from 0.3.122 on
   (`SalvagerDB.posted[].val`, copied to the sale as `val`); older sales take the price history (57) at the
   post of that material at that price each made before the sale, else at the sale. Used in the Expected value of
   gear (`Model.Value`, `ns.ValueOptions`; with the result rates of 99), so in buy limits (`Model.MaxBuy`), the Gear list, Lose %, Odds, the
   Market's disenchant value, the `planned` value of a disenchant and the value of what is held and listed (Reports, Materials view; the
   statement's stock, 97b).
   Not in the Disenchant value (`vals`, `value` of a disenchant: the market at the disenchant), nor in the cost
   shares (4). Measured 2026-11-26 on the user's data (96 sales): 0.998 for all materials together (1 copper under
   the lowest listing is about the average of the cheapest 20 when posting), 0.963 to 1.000 per material.
4. **Cost of disenchanted gear, shared per band** (0.3.120, the user, 2026-11-26; replaces the split of each
   item's price over what that one disenchant gave, which put the whole price on a lone dust and almost none on
   a shard). A band is quality, gear type and item level band (`Ledger.BandKey`). Each band has a pool
   (`ledger.pools`): the cost of its disenchants with a known cost, less what sales and conversions took, and per
   material its unsold units and their value at the disenchants (`vals`, after the cut). The pool's cost is
   shared over its materials by that value (largest remainder, so the parts add up to the copper); by units when
   none has a value. So every material of a band has the same cost per copper of value, and a new disenchant
   shares the band's cost again over all its unsold units. Units with a known cost outside the pools (opening
   stock, conversions, units given back) keep their own cost: the stock's cost minus the pools' parts. A sale or
   conversion takes its known units from each source in proportion to its units (whole units) and its cost at the
   average (in proportion to each source's cost), so the cost per value of a band stays the same; a source that
   gives up its last unit gives up all its cost. Sum of booked sale costs + cost of unsold units = what the known
   disenchants cost (plus opening stock), to the copper. Opening stock set by hand replaces what the pools held of
   that material, with its part of their cost. Breakdown and the Ledger's per-material share use the same rule over
   the band's whole record (paid × value ÷ the band's value). Ledgers from before 0.3.120 are recalculated once at
   load (`Ledger.Recost`, flag `ledger.jointCost`), after a backup (88): disenchants and sales replayed in time
   order; each sale's known units from the pools at that moment's average, units the pools do not hold (no record:
   opening stock, conversions) at their old cost; then units the pools hold beyond the stock go with their cost,
   and known units outside the pools keep the old average cost. One log line says it was done. A restored backup
   from before 0.3.120 is recalculated the same way.
5. **Stock valuation:** weighted average cost per material over its known-cost units, in every band pool and
   outside them (4). Break-even = ceil(average ÷ (1 − cut)). A sale is booked at that average and never changes
   afterwards.
6. **Purchases** are recorded when Salvager's Buy succeeds, and from the "Auction won" mail invoice (purchases
   from any addon). A mail that matches a purchase already recorded is not counted again. Matched to
   disenchants first in, first out per item ID. A disenchant with no recorded purchase adds its materials as
   units of unknown cost; they stay out of the average cost and break-even.
7. **Sales** are recorded from the "Auction successful" invoice: net = sale − cut. Deposits lost on expired or
   cancelled auctions are tracked (70d) and counted in the forecast (96).
8. **Opening stock** is entered by hand (`/salv stock`).
9. **Buying** needs one click per auction (`PlaceBid` needs a hardware event). Nothing buys on its own.
10. **Search pacing:** one search at a time, gated by `IsThrottledMessageSystemReady`; an item the client
    already holds results for is refreshed, never searched again (a second search never answers).
11. **Gear scan:** one browse pass per quality and gear type (so both are known without asking the game),
    every page read. The auction house does **not** return browse results in price order on Forever
    (measured 2026-11-25: stops triggered at random pages), so there is no early stop by price. Each row is
    judged when its page arrives, from the listing's price and item level against a band table built once
    per scan: no per-item game lookups. Later pages are read from the event's payload, not by re-reading the
    whole list. Item searches follow only for items under their buy limit, best margin first, at most 60.
12. **Item levels:** `SalvagerDB.ilvl` (learned from `GetItemInfo`, kept between sessions) first, else the
    listing's item level. Unknown items are requested in the background (5 per tick, 20 when a scan had to
    skip items), never in a burst. The scan log reports listings whose level differs from the game's data.
12a. **Not disenchantable:** gear with the client's "no disenchant" item flag (ItemSparse Flags_0 0x8000) is
    never valued or listed. `Salvager/NoDisenchant.lua` is generated by `scripts/make_item_data.py` from
    wago.tools: Forever's table, plus Classic Era's for items Forever's client table lacks (Forever's client
    holds only part of its items). Rerun after each Forever patch.
13. **Buy limits** per band and type can be set by hand (Limits window, 101; a tab before 0.3.128); the recommended limit stays visible.
    A hand-set limit is never above the band's value (67).
14. **Posting materials:** Post (Materials tab) first searches the material for its price now, then opens a
    window: price = 1 copper under the lowest listing that is not yours, quantity = what is in the bags.
    The post itself needs the player's click (`PostCommodity` is hardware-event restricted); when the game
    asks to confirm a low price, a second click calls `ConfirmPostCommodity`. A warning shows when the price
    is below the break-even (average cost ÷ 0.95); posting stays allowed.
15. **UI redraws** from events are limited to four per second; the log panel is not rebuilt during a scan.

16. **Ledger and Log** (`LedgerWindow.lua`, `LogWindow.lua`) are windows of their own (`Widgets.Window`: movable, resizable, place and size in
    `SalvagerDB.windows`). The Ledger window is built from `Ledger.History`: one entry per item (waiting purchases from
    the FIFO, finished ones from the disenchant records, which keep the purchase time and each material's value
    then; each material's part of the cost follows the band's rule, 4).
17. **Material price cadence:** while Play runs, the material prices are scanned again before a gear scan when
    the oldest is older than `priceRescan` (default 10 min, 0 = never). Basis, measured 2026-11-25 over about
    75 minutes (4 scans): all 24 materials moved under 3% in 7 minutes; over an hour several moved 5-12%; one
    thin market (Large Glimmering Shard) dropped 32% in 14 minutes. A material scan costs about 20 seconds.
18. **Searches wait for the browse:** a search sent while browse pages load made the auction house drop a
    page (seen 2026-11-25: a pass ended at 2500 of ~9000 items). The queue holds searches during a browse
    (except one the player asked for), and a page that does not come is asked for again twice (4 s each).
19. **Mail is booked by count, not by identity.** Mails have no ID, and two purchases (or sales) of the same
    item at the same price are identical mails. Until 0.3.4 a mail was skipped when one with the same sender,
    subject, money and days left had been booked: 4 of 5 Azure Silk Hoods bought together were lost
    (2026-11-25). Now a take starts a watch on that kind of mail, and one mail is booked for each that no
    longer holds its item or money at the next `MAIL_INBOX_UPDATE`, never more than the takes asked for.
    Known limit: with more than 50 mails, an identical one can slide into view and hide a take.
20. **Materials pop-out:** the materials list is one row builder (`Materials.Rows`) shown either in the main
    window's tab or in its own window, never both. Closing the window puts it back. Scans are not touched.
21. **Options open in the addon's own window.** The game's Settings panel closes other windows when it
    opens (it closed the main window, 2026-11-25), so the Options button, the minimap right-click and
    `/salv config` open `SalvagerOptionsFrame`. The same controls are also registered under the game's
    AddOns settings (`populate` fills both).
22. **Dropped requests:** the auction house takes one request at a time from all addons together and reports
    a dropped one with `AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED`, without saying whose. A search or page
    request of ours sent in the last 2 s is sent again at once (at most 3 times); otherwise the 3 s wait and
    one retry apply.
23. **Clear history** (Ledger window, with a confirmation) removes disenchants, sales and the purchase record.
    Stock and its costs stay; purchases not disenchanted yet stay, except items that can never be disenchanted.
24. **Layout is remembered.** `SalvagerDB.windows[key].open` is set only by deliberate actions (the addon's
    buttons and commands, a window's X). Escape and the auction house closing hide every window at once and
    do not change it. When the auction house opens (and `autoOpen`, `restoreWindows` are on) the Ledger, Log
    and Materials windows that were open are shown again. The main window's tab and the Ledger's view are
    kept too.
25. **Searches that get no answer** (measured 2026-11-25, 0.3.3 to 0.3.8): about one item search in four got
    no answer on its first try and none of them reported a drop; every second try worked. Cause not known
    (another addon sharing the one-request lock is the main suspect). Since 0.3.9: the wait is 2 s, a search
    is tried up to 3 times and stays next in line, the `_ADDED` result events also count as answers, and at
    the timeout the results are used if the game holds them. A refresh with no new answer uses the held
    results and logs it. Each round logs its check time and both counts.
26. **Buying first.** Purchases on their way are kept per auction ID (a fast run of Buy clicks used to
    overwrite the one being tracked, so 2 of 19 purchases were recorded only from their mail, 2026-11-25).
    While a purchase is on its way, or Buy was clicked in the last second, the search queue waits and a
    reported drop is not answered with a resend: the dropped request may be the purchase.
27. **The Post window** is a window of its own (`Widgets.Window`, fixed size), not pinned to the main window.
28. **Value is an average; Lose % is the chance for one item.** Deals show `Model.LossChance`: the chance that
    one disenchant is worth less than the price (quantities equally likely, Salvager bonus included when on, a
    material without a price worth nothing). Example measured 2026-11-25: Azure Silk Hood at 11s 46c, value
    12s 57c, lose chance 75% (every dust result loses). The Ledger's Odds view lists every band of every
    quality and gear type with the table, today's value and the player's own results where there are any.
29. **Your auctions** (`Listings.lua`). Read on every `OWNED_AUCTIONS_UPDATED` (whoever asked), asked for at
    auction house open and after a post or cancel, kept in `SalvagerDB.listings` so the Ledger shows them
    with the auction house closed ("as of"). A sold auction's `timeLeftSeconds` is the wait for its money.
    Price each: the unit price of a post made through Salvager is known for sure (`SalvagerDB.posted`); if a
    listing's reported price equals that times its quantity, this client reports totals and the rest are
    divided. Undercut = the lowest listing that is not yours is below your price each (one commodity search
    per listed material). Cancel needs a click per auction (`CancelAuction` is hardware-event restricted) and
    loses the deposit; searches wait while a cancel is on its way. Not verified in the game yet.
30. **Odds filters:** quality and gear type, kept with the Ledger window.
31. **Odds columns:** each band row shows Buy below (`ns.BuyLimit`: the hand-set limit, else value minus the
    minimum profit) and Lose % at that limit (`Model.LossChance` with the limit as the price: the risk when you
    pay the full limit; "-" when the limit is 0). Titles: Expected (the table), You got, Value now, Buy below,
    Lose %, Your average. `Widgets.List` columns take `help = { title, text }`, shown over the column title.
    0.3.125: each material row also has Rate used and Quantity used (the blend of 99, grey with "(few results)" under
    50 of yours), and the card's facts end with "Rates used from" (your disenchants the blend rests on, with or
    without the Salvager as buying counts it; the filters do not change it). Buy below and Loss chance use the
    blend. `Widgets.CardList` makes 10 cells a row (was 8).
    The lose colors are in one place (`ns.LoseText`), shared with the Gear list.
32. **The Gear list empties only for a scan started by a click** (Play, Scan gear, Scan both), and is then
    filled again. A round that Play starts by itself keeps the list: when the round has read the gear, rows of
    items no longer under their limit go, and the others are replaced as they are checked. (0.3.16 cleared at
    every round; the user meant clicks only, 2026-11-26.)
33. **Max price** (`maxPrice`, 0 = no limit): the most to pay for one item, whatever it is worth. The scan uses
    min(buy limit, max price) per band. It also keeps expensive items from taking the candidate checks.
34. **Main window layout** (rewritten 0.3.128, 101; the tab Deals is named Gear since 0.3.129): the tabs (Gear,
    Materials); the Gear view's "Scan settings"
    block (Scan, Buy, Levels rows) or the Materials view's filter row; the list in its own dark bordered panel with
    a title band and striped rows (`Widgets.Panel`); the footer.
35. **Materials list columns:** Material, Price, Age, Bags, Listed, Sold, Avg cost, Break-even, Profit, Sell price
    ratio (0.3.122, 3: in percent, grey with "(few sales)" under 5 sales), Time to sell (0.3.125, 100: grey with
    "(few sales)" under 5 sales; the main window makes 11 cells a row, was 10). "Units" is gone
    (the user found it useless). "Stock" (the ledger's count) is gone too: it confused, because it still
    counted what was posted or sold but not paid. Listed and Sold come from the last read of the player's
    auctions. Every material has a Post button, switched off when none is in the bags; the button column
    has a title.
36. **Cautious pricing** (`cautious`): the buy limit is measured from `Model.Value(...).low` (every material at
    its lowest amount, no Salvager bonus) and not from the average. Value, Profit and Lose % are unchanged.
37. **Level filter** (main window, "Levels" row): tick boxes for the 11 item level bands of uncommon gear
    (`levelBandsOff`) and a custom item level range (`ilvlMin`, `ilvlMax`, 0 = none). An item must pass both.
    It is applied to each listing as its page arrives, by item level. It does not narrow what the auction house
    sends (that query filters by required level, which does not map exactly to item level), so it does not
    shorten the loading of the gear list; the required-level range in the options does that.
38. **Tables look the same everywhere** (`Widgets.List`, unless `plain`): a sunken dark panel with a thin
    border, a title band, every second row shaded (zebra striping), the scroll bar inside. A row with
    `group = true` (an item with its materials under it, a band with its materials) gets a gold band. A view
    with sections is one table per section: the Ledger's Sales view is "On the auction house" and "Paid", each
    with its own title, columns and scroll bar. The Log stays a plain text list.
39. **Odds view: one table per band** (`Widgets.CardList`): a scrolling stack of cards, each a sunken panel
    with a gold title band (the band, then its facts: disenchants, value now, buy below, lose, your average),
    column titles and one striped row per material. Cards and rows are created as needed and reused.
40. **Sales are booked when seen sold** (own-auctions list), not when the mail is taken: a sold part is known by
    (auction ID, quantity, time the money is due ±20 s) in `ledger.seenSold`; the later mail marks those units
    paid (`Ledger.SalePaid`) and books only units never seen.
41. **Breakdown window**: a click on a material row opens where it came from, by item and by band, with cost per
    unit against the price now and the source's result as a whole (`Ledger.Breakdown`).
42. **Help text** sits behind a "?" button (one line per explanation); the footer keeps only scan results.
43. **Materials window fits its content**: fixed width, height = its rows (capped by the screen, then the list
    scrolls); no resize corner.
44. **Ledger tabs**: Sales, Purchases, Accuracy, Odds (Sales is the default). The Odds view can pop out to a window of its
    own (`SalvagerOddsFrame`), as the Materials list does; both share the filters saved under `windows.ledger`.
45. **Searches for the same thing are merged** (`Queue.Add`): one search goes out and every caller gets its
    answer; an urgent one (a click) takes the queued one's place at the front. Stop keeps urgent searches and
    ends a running undercut check. A buy and a cancel never run together (one error message, no sender).
46. **Play never stalls on a material scan:** a round that finds one running waits and tries again. "Scan
    owned" is let in during a gear scan; the full material scan is not.
47. **Clear history keeps what later mails need:** auction house purchases whose mail has not come, and sales
    whose money is due. A sold part is known by its auction ID and quantity; the time its money is due only
    tells two parts of the same size apart (measured 2026-11-26: that time moved by 36 s between two reads,
    which booked a sale twice). A missed part is booked from its mail.
48. **Quality names and colors** live in `Core.lua` (`ns.QUALITY_NAME`, `ns.QUALITY_COLOR`, `ns.BandName`).
    The tables (`Widgets.List`, `Widgets.CardList`) live in `Tables.lua`.
49. **One place per setting:** what the main window sets (gear, quality, min profit, max price, cautious
    pricing, item levels, item checks per scan) is not in the options window.
50. **Odds subtabs:** Armor and Weapons, one at a time (`windows.ledger.oddsTab`); they replace the gear type
    filter. Band names are written "Uncommon Armor", "Rare Weapons".
51. **Odds band filter:** the scan's item level bands as ranges (`windows.ledger.oddsBandsOff`); a rare or
    epic band shows when it overlaps a ticked range.
52. **Sales tables share their height by a draggable bar** (`windows.ledger.salesSplit`, 0.1 to 0.9, default
    0.45; right-click resets).
53. **The Post window shows the other sellers** (`Post.Market`, `Post.MarketRows`): their listings cheapest
    first, read from the search Post just made, with "Your price" and "Your break-even" in their place, the
    units ahead of your price and the units under your break-even. Two buttons set the price: Undercut lowest,
    Break-even. The game gives one line per price, not per auction.
54. **Combine or split** (`Post.Convert`): for an essence, the Post window says which form is the better one
    to sell (3 lesser = 1 greater, both ways, free). It compares the undercut price in each form and the units
    listed within 10% of the lowest price in each form: a gain under 3% = keep; a gain under 20% into a market
    more than twice as full (and over 60 lesser) = keep, "far more is listed there"; else convert. Combining is
    only advised with three or more in the bags. Classic's rule; not confirmed for Forever.
55. **Conversions are followed** (`Convert.lua`, `Ledger.Convert`): one form down and the other up by the
    matching amount in one bag update = a conversion; the cost moves to the new form. Units with no recorded
    cost count as zero in it.
56. **Cancel is the last button** of any group of buttons, everywhere (the user's rule).
57. **Market window** (`MarketWindow.lua`, `Chart.lua`, `History.lua`): every material scan adds a point to
    `SalvagerDB.history` (price, lowest listing, units listed; one point per 10 minutes, 600 per material).
    The window charts one material: price and lowest listing as lines, your break-even as a level, units
    listed as bars; ranges 6 hours, 24 hours, 7 days, all.
58. **Window sizing:** Ledger and popped-out Odds have a fixed width and a free height (`Widgets.Window`,
    `fixed = "vertical"`); Materials fits its content; the main, Log, Breakdown and Market windows are free.
59. **A round only removes what it has read.** Deals leave the list when their quality and gear type was
    browsed in full and the item is no longer under its limit. A browse that did not load in full (measured
    2026-11-26: "0 items in 0 pages, no page for 4s, given up") leaves that pass's deals as they are. A browse
    with no first page is sent again (twice) before it is given up.
60. **Market views:** Materials, Disenchant value (the band's value at each moment a material price was seen,
    with the last known price of each material, against the buy limit now), Profit (sales with a known cost,
    added up, and per day), Essences (3 lesser against 1 greater), By hour (average price per hour of the day).
    The history is filled once from older data (`Prices.SeedHistory`): last scans, log, disenchants, posts.
61. **Accuracy view** (Ledger, `Ledger.Accuracy`): per band and in total, over disenchants with a recorded
    purchase: Paid, Promised (value shown when bought), Got (value at the disenchant), Sold for (the same
    materials at the average price each really sold for; at the disenchant's price where none sold yet), and
    the planned and real profit. A second table per material: valued each against sold each. Sales are not
    tied to items (pooled stock), so "Sold for" per band is an estimate. Column names (0.3.117, the user: the
    window was too wide; abbreviations, UI.md Words 2): By band `Band | Disenchanted | Paid | Expected value (EV) |
    Disenchant value (DV) | DV/EV % | Sold value (SV) | SV/DV % | Expected profit (EP) | Actual profit (AP) | AP/EP %`;
    By material `Material | Units | Disenchant value each (DV) | Sold value each (SV) | SV - DV | SV/DV % | Units sold`.
    DV/EV % = Disenchant value against Expected value, SV/DV % = Sold value against Disenchant value (the same name
    in both tables), AP/EP % = (Actual profit − Expected profit) / |Expected profit|, "-" where Expected profit is 0;
    all in percent, green above and red below with "+" or "-" (0.3.133; 0.3.123 to 0.3.132 grey: a gap from a forecast was not counted as gold gained or lost;
    Expected profit and SV - DV too; Actual profit stays green or red). SV - DV is in coins, with a plain hyphen: the game
    font's minus sign (U+2212) is not confirmed. The help on each comparison names both values in full. Purchases
    (Expected value, Disenchant value, Profit) has no comparison column, so it keeps its titles without
    abbreviations; so does the Gear list. From 0.3.122 the Expected value of a purchase counts each unit at its price
    × sell price ratio, less the deposits lost per unit sold (3, 96); purchases from before keep the value they were
    shown with. Disenchant value stays at the market price, so SV/DV % still shows the sell price ratio and the
    price moves between the disenchant and the sale.
62. **(Replaced 2026-11-26 by 65.) A Buy click while the auction house is busy is not sent** (`IsThrottledMessageSystemReady` false): it
    would be thrown away without an answer (measured 2026-11-26: four clicks during a browse, none answered).
    Everything else is held for 3 s and the player clicks again. A "request dropped" within 2 s of a Buy
    click frees the row at once; a late "purchase completed" for it is still booked.
63. **Columns fit their content** (`Widgets.FitColumns`, `Widgets.TextWidth`): in every table (`Widgets.List`,
    `Widgets.CardList`, the main window's list) a column is as wide as its widest title or cell over all rows,
    plus 10 px; spare room stays at the right, except in a statement (`cols.statement`, 0.3.126, UI.md Statements 2):
    there the label column takes the spare room and the amounts end at the table's right edge. The title is measured as it shows: with the sort arrow on the
    sorted column (0.3.124: the main window's Deals measured "Return" without its arrow, which then ran into "Loss
    chance"). A column of live values has a `sample`, its widest possible value with every digit the widest one, so
    it keeps its width while the value changes: the Sales tables' Time ("00:00:00"), the Materials list's Age ("00m",
    also in the main window's Materials tab). The widths written in the code
    are the fallback where text cannot be measured, and the width of columns with input boxes. The Log is left out.
64. **Sales view:** two subtabs. "Open and sold" has two tables: Open auctions (only what is still for sale)
    and Sold (sales whose money is not collected yet, with a countdown). "History" lists the sales whose mail
    was taken. The game keeps a sold auction in its own list until the money is mailed; the addon shows it
    as a sale, not as an auction.
65. **A Buy click always buys** (the user's rule: a deal is lost if it waits). Nothing ever asks the player to
    wait or click again. With the auction house free the purchase is sent in the click. With it busy
    (`IsThrottledMessageSystemReady` false) a purchase sent now is lost with no answer and no event (measured
    2026-11-26, 03:17: five such clicks, "no answer in 10s"), so it is sent on the next
    `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`, ahead of the whole queue, one purchase per "ready". To keep
    the line free, the scan holds while the mouse is on a Buy button (`Scanner.Aim`, 4 s at most) and while a
    purchase is on its way. A purchase the auction house reports as dropped is sent again by the addon when the
    auction house is ready (`AUCTION_HOUSE_THROTTLED_SYSTEM_READY`), ahead of every search and page, up to 3
    times. `PlaceBid` is documented as restricted, so the game may refuse a purchase that is not from a click:
    on `ADDON_ACTION_BLOCKED`/`FORBIDDEN` for Salvager, `SalvagerDB.buyResendBlocked` is set, resends stop for
    good, and a dropped purchase frees its row instead. Not yet measured in the game.
66. **An item's own quality decides its value, not the browse it came in.** Measured 2026-11-26 03:15: the
    uncommon browse stalled, the rare pass started, and late uncommon pages were judged as rare (an uncommon
    headband valued at one Large Radiant Shard, 2g 23s instead of 72s). `judge` drops an item whose known
    quality or gear type differs from the pass; `readAuctions` drops an auction whose own link gives another
    quality, gear type or item level band than the one it was valued with. A search answer is matched to
    its task by item ID and suffix. Rule: data that arrives later (pages, search answers) is checked
    against the thing it is used for, never trusted for the context it arrives in.
67. **Fail closed on what is not known** (0.3.79, after the review of 2026-11-26).
    - a. `readAuctions` lists an auction only when its own link gives quality, gear type and item level band
       (unknown = left out, logged). The quality comes from the link first (`ns.LinkQuality`: Forever's
       `|cnIQ<q>:` or the quality color). `judge` reads quality from `SalvagerDB.quality` (learned with the item
       level, `Items.Quality`), never from `GetItemInfo`, so a page sends no burst of item requests.
    - b. Thin markets: each scanned price gets a ceiling from the history of the last 24 h before the scan
       (`History.Ceiling`: 1.25 × median with 3+ points; the median itself when under 5 units are listed).
       `ns.PriceOf` never goes over it. One silly listing cannot raise a band's value.
    - c. A last price (scan found none) is used for one day at most; then the material counts as missing.
    - d. A hand-set buy limit is capped at the value (a falling market never buys at a loss).
    - e. The auction house's single error event is taken only by the module that sent the last request
       (`ns.NoteRequest` / `ns.ErrorIs`: buy, post, cancel). A purchase given up (error or no answer) stays
       in `dropped`, so a late `PURCHASE_COMPLETED` is still booked.
    - f. An auction being bought is never listed twice; a group row shows the auction its Buy button buys.
       A recheck and a settings change use the limits of now.
68. **Gold journal** (`Journal.lua` pure, `Gold.lua` glue; `SalvagerDB.money`): every change of a
    character's gold (`PLAYER_MONEY`), with its balance and kind, at most 20 000 entries. Kinds come from
    what the addon itself did (purchase −buyout, deposit, cancel fee, mail money taken: auction sale or
    other mail) matched by exact amount, else from the window open (vendor, merchant, repair, trade, mail,
    flight, training, auction house), else "other". A change found at login is "unseen" (the addon was off).
    The window is the one opened last (opening one closes the others): the client does not always send
    MAIL_CLOSED (measured 2026-11-26: every auction house purchase after a mailbox visit was booked as mail),
    so the interaction manager's events (`PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE`) count too. The gold
    is never read at logout (the game reports 0 then). The character is "Name-Realm" once the game tells the
    realm (it can be empty at login: records kept as "Name-" move to the full name).
    `/salv gold <hours>`: start, now, money in the mail (unpaid sales), after pickup, by kind, and the buys
    that lost, marking those that were valued as something they were not. Each purchase keeps its judgment
    (`j` = quality, gear type, band, item level, version), copied to the disenchant as `judged`.
69. **Activity log:** 5000 lines; a `== <date> ==` line starts each day; session lines at login and logout
    (character, gold, version). The Log window filters all lines, trades and gold, or errors (remembered).
70. **Books, after the review of 2026-11-26** (0.3.79):
    - a. `PostCommodity` and `CancelAuction` are restricted (they need the click): they cannot wait for a
       purchase and go out later, so Post and Cancel undercut are off while a purchase is on its way, with
       the reason in the tooltip.
    - b. A sale's profit counts only units with a known cost; the net of the others is `netUntracked`
       (old records are split at load). The mail's real cut replaces the estimate when the sale is paid.
    - c. (Withdrawn 2026-11-26, 0.3.85: 47 holds again.) A due-time limit of 120 s on the match of a sold
       part booked 6 sales twice within the hour: the read just after a post gave due times 130–150 s later
       than the read before it. The due time only tells parts of one size apart, never decides that a part
       is new. `Ledger.DropDoubleSales` runs once more (`doubleSalesFixed = 2`) and gives the units back.
    - d. A lost deposit (auction cancelled or expired) is a `sales` record with `lost`, `count = 0`, `qty`,
       and the deposit as its loss: in the profit and totals, not in Accuracy or Breakdown. The deposit of
       each post is kept in `SalvagerDB.posted`. An expiry is seen on `AUCTION_HOUSE_AUCTIONS_EXPIRED`, or
       between two reads less than 1 h apart.
    - e. Cancel undercut is offered only when the undercut gap × quantity covers the cancel cost plus the
       new deposit; lowest prices older than 2 min are ignored.
    - f. Post's suggested price skips a thin outlier: a listing under 70% of the average of the cheapest
       N units with fewer than 10% of N units. Selling below break-even stays allowed (14), with its warning.
    - g. A conversion is not read within 2 s of loot, mail or a post; the new units keep the known-cost
       share (rounded up), the rest stay unknown. A disenchant books materials only; the loot source is
       checked when the client gives it (`GetLootSourceInfo`).
    - h. Records waiting more than 30 days (an unmatched purchase mail, a purchase never disenchanted, a sale
       never paid) are dropped or counted as paid at load. A reset keeps `seenSold`; a new ledger starts
       with `doubleSalesFixed`.
71. **A click that cannot run now runs by itself** (`ns.Defer`): a gear scan clicked during a material scan,
    a material scan during a gear scan or an undercut check, and an undercut check during a material scan
    start when the other is done (dropped if the auction house closes). The chat says when it starts.
72. **Gold view** (Reports window, 79; rewritten 0.3.123: the user found the old one very hard to understand; 0.3.126:
    the Sessions subtab became a choice of the period, the user, 2026-11-26): two subtabs on the subtab row, kept with
    the window (`goldTab`; a saved "sessions" falls back to Statement). "Statement" first (97). "All gold changes":
    every change of gold in the period picked, newest first (What, Time, Change, Kind, Gold after). A session is picked
    in the Period filter (79); a period longer than one session (the last hours or days, All time) ends the statement
    with a Sessions part: one line per session of this character in it, newest first (its start and length, "(now)"
    for the open one; amount: its Total; tooltip: Trading profit and Total), a click shows its statement. One amount
    column, not four: the statement keeps its two columns (label, amount) and the trading profit is in the tooltip.
    The old sums (start, now, mail, by kind, the buys that lost and the part valued wrong) left the view: the statement
    says it better; `/salv gold <hours>` keeps them.
73. **Min return** (`minReturn`, percent, 0 = off) next to the min profit: the recommended limit is the lower
    of value − min profit and value ÷ (1 + min return) (`Model.MaxBuy`, which also says which rule set it; the
    value is the forecast's: price × sell price ratio after the cut, less deposits lost, 3 and 96; the
    Limits tab marks a limit set by the return with "%"). Deals have a Return column (expected profit ÷
    buyout; Return per day is in the row's tooltip, 100); a click on Expected profit or Return orders the list (`dealSort`, remembered), and the item
    checks of a scan go in the same order. Reason: with more supply than gold, return on each gold paid is
    what grows the gain (measured 2026-11-26: 82 of 361 Azure Silk Hoods under the limit in one check).
74. **Measured 2026-11-26, first session with the Arcane Salvager** (36 Uncommon armor, item level 26–30):
    - a. The bonus is real: Soul Dust came as 1 / 2 / 3 units 11 / 5 / 10 times (never 3 in the 41 dust
       results before). Mean 1.96 against 1.44 before: +0.52 per dust result, as the 50% model says (2.0).
       The shape is not "+1 half of the time" (that gives 7 / 13 / 6); more data needed. Essences: 5 results,
       none above 2, too few to say if they get the bonus.
       0.3.125, on the saved data of 2026-11-26 (378 disenchants, 266 with the Salvager: 200 by the effect, 36 by
       the player, 20 by the setting, 10 by a result above the table): **essences get the bonus, but less than
       dust.** With the Salvager, 54 essence results came as 1 / 2 / 3 units 24 / 18 / 12 times (mean 1.78; 12 above
       the table's 2); without it, 14 came as 7 / 7 / 0 (mean 1.50, the table's). So about +0.28 per essence result
       (± 0.11), against +0.5 in the model and +0.60 for Soul Dust (2.04 with, 1.44 without). Neither material has the
       shape of "+1 half of the time". The blend (99) answers it per band: Greater Astral Essence in Uncommon Armor
       26-30 with the Salvager (51 results) is counted at 1.82 each (table with the bonus: 2.00), Soul Dust at 2.04.
    - b. No Salvager effect was found on the player by name, and the snapshots were full (they kept the
       first 30). The buff is **Boosted Disenchanting, spell 1283701** (wowhead.com/forever/spell=1283701):
       "Disenchanting boosted from time spent near Arcane Salvager. While near Arcane Salvager, chance of
       bonus disenchanting output is increased." It is matched by ID (and by name); its stacks are kept with
       each disenchant (`salvagerStacks`), in case the bonus grows with the time spent near the Salvager.
       The first batch (06:14:42–06:17:12) is marked as with the Salvager once (`salvagerBy = "player"`). Now the newest 30 stay, and a disenchant counts as "with Salvager" when the effect is seen,
       when a result has more units than the table allows, or when the setting is `on` (`salvagerBy`).
    - c. `PlaceBid` without a click is blocked by the game (`buyResendBlocked` set at 03:26): a purchase
       cannot be resent by the addon (65).
    - d. A "request dropped" event just after a Buy click, with a search just sent, is about the search: 23
       such drops in 36 purchases, and every purchase went through. The purchase is freed only when no
       search was sent in the last 2 s.
75. **Measured 2026-11-26 06:21:** (a) the game sends `AUCTION_CANCELED` when an auction sells too: each sale
    was first booked as a cancel with its deposit lost. It is a cancel only when `CancelAuction` was called
    for that auction in the last 30 s (hooked, so other windows count); else your auctions are read again.
    The false records of 0.3.79–0.3.83 are removed once. (b) `GetRealmName` gives nothing on this client:
    the character is its name alone, after a 3 s wait; a change of gold never waits for it.
76. **The Arcane Salvager camp: 15 minutes, then about 1 hour of cooldown** (the user, 2026-11-26). So it limits
    the disenchants with the bonus to one batch per hour or so. Bought gear waits in the bags for the next camp.
77. **Measured 2026-11-26 13:30 (second Salvager batch, 30 Azure Silk Hoods):**
    - a. A real cancel gets no event in this client (03:15, 06:28 and before), while a sale gets
       `AUCTION_CANCELED` (75a). A cancel is now known from the next read of your auctions: an auction a
       cancel was asked for (`CancelAuction` hooked, any window) that is gone unsold. The read is asked 1 s
       after the call.
    - b. With resends blocked by the game (`buyResendBlocked`), "request dropped" never frees a purchase:
       it waits for its answer or for 10 s. (06:31: every purchase was freed with "click Buy again" and
       went through; the extra clicks then gave "could not buy".)
    - c. An "open all" takes several mails before the gold is read: one change of gold is matched to the
       first expectations, in order, that add up to it (8g 40s 75c from 5 sales mails at 13:28).
    - d. `make install` checks the version on the gaming PC after the copy (0.3.86 did not arrive the first time).
78. **The main window leads** (2026-11-26, the user): when it closes, every Salvager window closes with it
    (hidden, not marked closed: `UI.HideOthers`), and they come back with it (`UI.RestoreWindows` on its
    OnShow and on `AUCTION_HOUSE_SHOW`). The "Auction house" button (top row, off while the auction house is
    closed) closes the Salvager windows and leaves the game's auction house showing; scans and checks go on.
    A "Salvager" button opens and closes them again. It sits above the top right corner of the auction house
    window: under it are the game's tabs and ForeverForge's "ForeverForge AH" button (0.3.89 put it there and
    they overlapped). It is on the game's window and on ForeverForge's (`ForeverForgeAuctionFrame`, which
    keeps the game's one shown but invisible), can be dragged, and keeps its place (`windows.ahButton`).
    The "Auction house" button only hides the Salvager windows: it never shows the game's window, since
    ForeverForge hides that one on purpose. Facts read from ForeverForge Auction (no code taken): its
    "ForeverForge AH" button hangs below the game's window, bottom right, and can be dragged (kept in its own
    saved data), so its overlaps can be fixed by dragging it, with no patch.
79. **Reports window** (`ReportsWindow.lua`, the main window's Reports button, `/salv reports`): one period for all
    views, remembered (`range`), picked in the "Period" filter (0.3.126, UI.md Controls 1-5: it left the tab row, where it
    read "Time", for the filter row of every view): This session (0.3.123, 97), each past session of this character
    ("11-26 18:49, 1 h 10 min", newest first, the newest 15 (`Reports.MENU_SESSIONS`); older ones are picked from the
    Sessions part of All time, 72), Last 24 hours, Last 7 days, Last 30 days, All time (`range = "s:<start>"` for a
    session; that time has an end too: `Ledger.Profits(state, from, keep, to)`). The rows from the top: the view tabs,
    the Gold or Gear subtabs, the filter row (Period, then Gear, Quality, Bands, Salvager on Gear), the
    table. The line that repeated the period and the view's help left: the period shows in its filter and in the
    statement's first line, the help is on the tab. Width at least 890 (was 760), so the longest filter row fits.
    Views (tabs, 0.3.129: Gold, Gear, Materials): Gold (72, 97);
    Gear (tab named Profit until 0.3.127, the user), with two subtabs (0.3.129, the user; the Items tab is gone):
    Bands first, the profit by quality and gear type with its bands under it (`Ledger.Profits`: disenchants with a known
    cost; Sold value = the materials at what one unit really sold for, at their disenchant value while that
    material has not sold; Profit = Sold value − Paid; grey under 20 disenchants; its headings open and close, 103),
    then History, every piece of gear, best first (the old Items view); a saved view "profit" or "items" moves to
    Gear with that subtab, the column sets keep their names (`reports.profit`, `reports.items`). Materials (got,
    sold, sold for, cost of sold, deposits lost, profit, held and listed now and their value).
    Bands groups by gear type, then quality, then band (the range only, "26-30"). Both Gear subtabs have
    filters on their filter row (under the subtabs) after the period (gear type, quality, item level band, with or without the Salvager;
    remembered; at least one ticked). Materials: Held = bags and bank (`GetItemCount(id, true)`), Listed = your
    unsold auctions as last read; the ledger's stock counts both and is not shown as "in stock".
80. **One grouping for every list of bands** (the user, 2026-11-26): gear type (Armor, then Weapons), quality
    under it, then each band by its range only ("26-30", never "item level 26-30"). `ns.GroupedRows` builds
    it, with totals on the headings where the table has totals: Market's Disenchant value, Ledger's
    Accuracy, Reports' Gear, Breakdown's bands. Odds cards sit under the Armor/Weapons subtab and are titled
    "Uncommon 26-30". A sorted grouped list sorts inside each group (`section`, `head`). `/salv report` too
    (Armor, Uncommon 26-30: ...). The main window's Limits tab is a table of two halves instead (the user,
    0.3.97): an Armor title over its Recommended and Override price threshold columns, a Weapons title over
    its two; the rows are the bands of every quality (whatever the scan looks at; grey where it does not),
    under a heading per quality, the range only. Vertical lines after the Item level column and between the
    halves (`groupHeader`, `dividers` of a main window view).
82. **Ledger Purchases** (0.3.96): one row per item (newest first) with its count and totals; a click opens it
    to show each purchase with what it gave (`purchaseFilter().open`). A search box (any part of the name,
    any case) and filters by gear type, quality and item level band sit on the row under the tabs; all kept
    in `SalvagerDB.windows.ledger.purchaseFilter`. (0.3.98) The open / close sign comes first on the row,
    18 px, before the item's icon (`data.open` of a `Widgets.List` row); a "Not disenchanted" check box shows
    or hides what is bought and not disenchanted yet; a click on a column title orders the items by it (again
    turns the order round), by Profit, the best first, until then.
81. **Charts:** the mouse over a chart shows the values at the nearest moment that has one (a mark, a dot per
    line, a tooltip with the time, each line, the units listed and each level; `chart.Nearest`). Market's
    "By hour" is now "Time of day", with a mark at every hour and a label every 3 hours (`xTicks`).
83. **Filters as usual, headings that close** (0.3.99): one filter row (`filterRow` in LedgerWindow.lua:
    Gear, Quality, Bands, and Salvager where the data says it) on the row under the Ledger's tabs, in
    Purchases, Accuracy and Odds; each view keeps its own (`purchaseFilter`, `accuracyFilter`,
    `oddsFilter` in `SalvagerDB.windows.ledger`). Odds lost its Armor/Weapons subtabs (the Gear filter does
    it; old settings move over once). Every heading of a grouped list opens and closes (`ns.GroupedRows`
    `opts.collapsed`; one implementation and look since 0.3.129, 103); Odds cards too, each band on its own (`Widgets.CardList`: `heading`, `open`,
    `onClick`, `indent`). Accuracy has an AP/EP % column in percent (SDD 61), on the headings
    too, after Actual profit (0.3.115, the user; it replaces the gold Profit difference of 0.3.99/0.3.110). The odds window is 740 wide (0.3.101): "Only bands with my data" on a row of its own under
    the filter row; the Odds cards sit in 12 px per level (22 in the other tables).
84. **The Materials window fits its list** (0.3.100): as wide as its columns need, the Post column ending
    with its button (`list.neededWidth` from `Widgets.List`), at least 620 for the row above the list (help
    and check box from the right, the status cut before them).
85. **Main window list** (0.3.102): the column the Gear list is sorted by has the arrow icon (as in the
    Market and the Ledger), not "v"; the "?" help is the first thing on the row of column titles, and its
    first line says what the list is sorted by and how to change it. Limits' and the Gear tab's help say the column
    names in use (Recommended / Override price threshold; Expected value, Expected profit, Return).
86. **Where a listing stands** (`StandWindow.lua`, 0.3.104): a click on an auction of yours for sale (Ledger,
    Sales, Open auctions) searches its material and shows the other sellers' price lines (`Post.MarketRows`,
    with your price and your break-even in their place), and above them: your listing, the units ahead of
    it, and what being first again costs (the gap × your units, against the deposit lost and the new one,
    `Listings.RepostCost`), with a hint: under break-even (wait), few units ahead (wait), many ahead (a
    repost sells sooner if the gap pays its deposits).
87. **Main window status at the bottom** (0.3.105; moved 0.3.111, 93): the spinner and the status text (what the
    addon is doing now) sit at the bottom right under the list, left of the "Buy Top" button, as wide as the text
    and at most half the room left of the button. The footer takes the room on their left, in two lines, each one
    line cut at the spinner: line 1 is what the last scan found (deals, items, limits, max price), line 2 the
    item closest to its buy limit ("Closest: ..."). The list's bottom is one line higher for it. (0.3.128, 101: the
    two lines sit over the footer's row of buttons; the status and the gold at the right of line 1.)
88. **Clear history lives in the options, with backups** (0.3.106, the user): Options, Data has Clear history,
    Restore backup (with the date of the last copy; off when there is none) and the size of the saved data
    (`Util.SavedSize`: within 0.3% of the real file, measured 2026-11-26). The confirmation says what is lost
    (every purchase, disenchant and sale record; the Ledger, Reports, Accuracy and Odds start empty) and what
    stays (stock and its costs, purchases not disenchanted yet). Before a clear or `/salv reset ledger`, the
    whole ledger is copied into `SalvagerBackup`, a saved variable of its own (the game writes it into the same
    file; an addon cannot write other files), last 3 kept. Restore (`/salv restore`, it asks) puts the last
    copy back and keeps what it replaces as a backup, so it can be undone too.
89. **Published on CurseForge** (2026-11-26, the user): MIT license (`LICENSE`, also in the zip). `make release`
    (`scripts/release.py`, Python standard library only) zips the `Salvager` folder, uploads it through the
    CurseForge upload API for the game version named after the TOC's interface (16001 = 1.60.1, Forever),
    tags `v<version>` and pushes the tag to GitHub (`origin`); the changelog is the commit subjects since the last tag. Each upload is a new
    version: it refuses a dirty tree or a version already tagged. Local settings (install host, AddOns
    folder, CurseForge token and project) live in `.env`, never in the repo. Forever only: the file gets one
    game version, of the Forever type (`CURSEFORGE_GAME_VERSION_TYPE=88568`), and the TOC has only interface
    16001, so other clients do not load it. Blizzard's own Forever TOCs have no flavor suffix, so neither does ours.
90. **Purchases view: two subtabs and the bag space** (0.3.108, the user). "All purchases" (first) is the list
    as before, with its search and filters on the filter row under the subtabs. "Not picked up (n)" lists the
    purchases made with Buy whose "Auction won" mail is not taken yet (`Ledger.NotPickedUp`: `ledger.bought`
    without `mail`, with link, expected value and item level from the matching purchase record), oldest
    first: its mail came first and runs out first. A heading row has the count, the total paid and the total
    expected value. Purchases known only from their mail (other addons) are not in it: the addon sees them
    when they are taken. No arrival countdown: the delay of a buyer's mail on Forever is not measured. In the
    footer, at the right (the subtab row until 0.3.128, 101), for both subtabs: bag space, free of total slots of the backpack and the
    bags of family 0 (`Items.BagSpace`, `C_Container.GetContainerNumFreeSlots`; profession bags left out),
    live on `BAG_UPDATE_DELAYED`. Shown as a bag icon and free/total, no words (0.3.109, the user). While
    items wait in the mail, an arrow (the game's `ChatFrameExpandArrow` texture: its fonts have no "→") and
    the free/total after taking them all, one slot each (gear does not stack): `12/26 → 4/26` (0.3.110, the
    user). Below 0 it is the slots missing as a negative (`-3/26`), red with the alert sign after it.
91. **Tables show every column; the Ledger fits its tables** (0.3.110). `Widgets.List` made 10 cells a row,
    so the 11th column of Accuracy, By band (then Profit difference) was never drawn, while its width still counted
    and squeezed the first column ("Uncom..."). It now has 12, and `SetColumns` refuses more than it has (so
    does `Widgets.CardList`) instead of cutting them. `list.neededWidth` counts the first column at its full
    width even where the list cut it. The Ledger window is as wide as the tables on show need, at least 860
    (`f.FitWidth` of `Widgets.Window`: width and resize bounds); its height stays the player's. 0.3.114: the
    bounds are set first, then the width. 0.3.110 to 0.3.113 set the width first, while the bounds made at
    build still held it at 860; a client that keeps a frame inside its bounds on `SetWidth` leaves it there,
    and the last columns of By band (then Profit difference, Actual profit) do not fit and are left out. The
    stand-in did not model the bounds. Not yet measured in the client: the layout dump (94) shows it. 0.3.124: each width
    change also makes the window's clamp rect again (98), so a wider Ledger still keeps 40 px on the screen.
92. **The version in the title bar** (0.3.110, the user): every window made by `Widgets.Window`, and the main
    window, shows `v<version>` (`ns.VERSION`, from the TOC through `C_AddOns.GetAddOnMetadata`) at the left
    end of its title bar (`f.TitleBg`), small and dim (`GameFontDisableSmall`). Where it would come within
    12 px of the centered title at the window's smallest width, it is left out (`Widgets.TitleVersion`).
93. **Buy Top** (0.3.111, the user; 0.3.112; "Buy Top" since 0.3.129): a button at the bottom right of the main
    window, left of the resize grip, on every tab. One click buys the single best auction of the Gear list by the
    active sort, from any row
    (`UI.TopDeal`): of every auction not being bought, the one with the highest Expected profit (profit sort) or
    Return (return sort), each auction's own (`d.profit`, `Scanner.Return`); ties go to the other number, then the
    lower buyout, then the auction ID. Not the top row: after the best auction of a row of several is bought, the
    next click can buy another item's auction before that row's dearer ones (0.3.111 followed the row, a fix of
    the user's intent in 0.3.112). The list does not move. When the gold is short for the best auction, the click
    buys the best one the gold covers, and the tooltip names the skipped one. It goes through `Scanner.Buy`, as a
    row's Buy: the click is the hardware event, the scan holds, a busy auction house gets it as soon as it is
    ready (65). The mouse on it holds the scan (`Scanner.Aim`). Off, with the reason in its tooltip: auction house
    closed, no gear scan yet, the list empty, every deal being bought, not enough gold for any (the best one is
    named). Its tooltip shows the gear and the deal's lines of what the click buys (`UI.AddDealLines`, as a Gear
    row's: Item level, Buyout, Expected value, Expected profit, Return, Loss chance, Time to sell, Return per day),
    and follows the list while it shows. Above the button, right-aligned to it (0.3.112, the user): the icon and the
    link of the gear the next click buys, one line, at most half the room left of the button, cut there; empty
    while the button is off; the mouse on it shows the game's tooltip of the gear and the same deal lines (0.3.129,
    the user: one function for the row and for this, so both always match). It sits between the button's top and the
    list's bottom (37 to 51 px above the window's bottom, over the footer's first line), so the list keeps its
    place.
94. **Layout dump for the agent** (0.3.114; complete enough to draw in 0.3.119): on `PLAYER_LOGOUT` (logout and
    /reload; the game writes the saved variables right after) `Layout.lua` walks every Salvager window that exists into
    `SalvagerDB.layout`, replaced each time: `{ version, time, entries, size, full, screen = { w, h, scale, eff },
    hidden, windows = { [name] = { shown, w, h, x, y, scale, eff, view, regions, lists, dropped, rowsDropped } } }`
    (`screen`: `GetScreenWidth/Height`, UIParent's scale and effective scale; a window's `x`, `y` are its left and
    top; all sizes 0.1 px, as strings).
    A region is one tab-separated line: path key (parent key + the field name, the frame name, or `c<i>` / `r<i>`),
    type, flags (S shown, V visible, T text cut, D disabled control, C checked, K clips its children), left,bottom,width,height, text (in
    full while visible, else 80 characters), then `k=v` fields where they apply: `f` font size, `j` justification
    (L C R), `c` text color (FontString, when not white) or vertex color (Texture, when not white) as `rrggbbaa`, `sw`
    the text's own width as the client measures it (`GetUnboundedStringWidth`), `d` draw layer (BG BD A O H), `ct` a
    color texture's color, `tex` the texture's atlas or file name (last part, 40 characters), `a` alpha below 1,
    `fl` frame level, `bg` and `bd` backdrop and border color. The client has no getter for a color texture: a
    `hooksecurefunc` on the shared texture methods' `SetColorTexture` keeps it in a weak table.
    Each `Widgets.List` also has its own record: `w`, `needed` (`neededWidth`), `offset`, `count`, columns as set
    (title, width), `set` and `hidden` (95), `cells`, `rowsShown`, each title (text, shown, width, cut), and `rows`:
    every row on screen (not hidden, not scrolled away), `{ n = data index, rect, cells, parts }`; a cell is flags,
    width, text, rect, then the `k=v` fields (the first three as the 0.3.114 `row1`, which `rows` replaces); `parts`
    are region lines of the row's open sign, icon, warning sign and button. The list's own regions and children are
    walked, its rows and title help areas are not. Hidden frames are not opened; depth 8, 3000 regions, windows on
    show first. Past 600 KB the regions go, from the last window, then the lists' rows, from the last window. Each
    window in `pcall`: a failure is `{ error = msg }`. No chat output, no option.
    `make layout` (`scripts/layout.py`, Python standard library): finds the newest
    `<ADDONS_DIR>/../../WTF/Account/*/SavedVariables/Salvager.lua` on `INSTALL_HOST` (PowerShell over SSH), copies it
    to `.agents/tmp/layout/` (mode 0600), draws each window that was on show as `<window>.svg` and `.png`
    (`rsvg-convert` with DejaVu in Docker, image `salvager-layout` from `scripts/layout/Dockerfile`; texts at the
    client's measured width, WoW color codes, coins as colored dots, other inline textures as squares) and prints per
    window: texts cut, texts wider than their box or cell, regions outside the window, the window partly off the
    screen (allowed, 98) or past its clamp, controls and texts that overlap (a text button counts by its frame, a button without text by its art outside the
    highlight layer), lists narrower than their columns need. `--file <path>` draws a local copy. It is the way to
    see a window: /reload, `make layout`, read the PNG, instead of asking the user for a screenshot.
95. **Column chooser** (0.3.117, the user): every table with column titles (`Widgets.List`, the Odds cards of
    `Widgets.CardList`, the main window's Gear and Materials tabs) has a small button at the right end of its title
    band, over the scroll bar, where the titles end (`Widgets.ColumnChooser`): three gold squares stacked (the game
    fonts have no vertical ellipsis). Tooltip "Columns". A click opens a menu under it in the drop-down look: one
    check row per column (its title, without the sort arrow, `col.key`), ticked = shown; a click shows or hides the
    column at once and the menu stays open; it closes on a click outside, on Escape (the keyboard is not taken in
    combat), or on the button. Last row: Show all (off when nothing is hidden). The first column and the buttons'
    column (Buy, Post) are ticked and greyed, the reason in their tooltip. Saved in `SalvagerDB.columns[setId][title]
    = false`, per column set (`SetColumns(cols, setId)`: the COLUMNS key in the Ledger, `market.<view>`,
    `reports.<table>`, `breakdown.item/band`, `stand`, `post.market`, `odds`; `deals` and `materials` in the main window,
    `materials` shared with the Materials window), by title, so a reorder keeps it; unknown titles are ignored. A
    hidden column takes no width: `neededWidth`, the Ledger's `FitWidth` and the Materials window follow the visible
    columns; rows, headings and grouped rows hide the same cells. A hidden sort column keeps the sort; its arrow is
    not shown. Not covered: Limits (its columns go in pairs under Armor and Weapons, two hold input boxes) and the
    Log (no titles). The layout dump (94) has per list `set` and `hidden`, and `hidden[set]` as saved for every set.
    No option and no slash command: Show all is the reset.
96. **Deposits lost in the forecast** (0.3.122, the user, 2026-11-26). The Expected value of gear is net of the
    deposits the auction house keeps on expired and cancelled auctions (70d): per material, deposits lost ÷ units
    sold over the last 30 days, as a share `k` of the deposit of one unit in one post (`Ledger.DepositRates`;
    one unit's deposit = your posts of it, deposit ÷ units, else `CalculateCommodityDeposit` for one unit at your
    post duration, `ns.UnitDeposit`). Under 5 sales `k` is pulled toward all materials together, and that toward 1,
    as the sell price ratio is (3); with no data `k` = 1: one post's deposit lost per unit sold. Each result
    costs chance × units × `k` × the unit deposit (`Model.Value` `deposit`, `ns.DepositPerUnit`); Lose % uses the
    same. The material's tooltip shows its sell price ratio with its sales count ("few sales" under 5) and the
    deposits lost per unit sold. Measured 2026-11-26 on the user's data: 16 copper lost over 94 sales (Soul Dust
    0.016 c, Greater Astral Essence 0.125 c per unit sold). With the sell price ratio, it lowers the Expected
    profit of the 377 disenchants in Accuracy by 1.2% (165 236 to 163 187 copper) against an Actual profit of
    123 128: the forecast's gap to Actual profit (−25.5%) is mostly Disenchant value against Expected value
    (EV 719 040, DV 687 939) and price moves between the disenchant and the sale (SV 676 932), not the undercut
    or the deposits.

97. **Sessions and the statement** (0.3.123, the user, 2026-11-26; `Statement.lua` pure, `Gold.lua` glue,
    `SalvagerDB.sessions`).
    - a. A session runs from login to logout. `PLAYER_ENTERING_WORLD` with `isReloadingUi` keeps the open session
       (`sessions.open`, saved); any other load closes it and starts one. `PLAYER_LOGOUT` (logout and /reload; the
       client does not say which) keeps the time as the session's last; every change of gold or of the ledger does
       too. So a session whose logout was never seen (a crash) is closed at the next login at its last known time.
       Another character's login closes it as well. At most 200 closed sessions.
    - b. Stock snapshots (`sessions.snaps`, at most 1000): `{ t, v, c }` at each session start and at each
       `PLAYER_LOGOUT`. Stock value (`Statement.StockValue`): every unit in the ledger's stock (bags, bank, listed) at
       what one unit is worth to the forecast (0.3.124, `Model.UnitValue`, `ns.UnitValue`: price × sell price ratio ×
       (1 − cut) − deposits lost per unit sold, never below 0; 3, 96), as the Reports' Materials view values what is held
       and listed, so every report agrees (0.3.123 counted price × (1 − cut)); gear bought and not disenchanted yet at its
       expected value at purchase (`ev`). Without a price or an expected value, at its cost (no gain, no loss). Cost:
       the stock's known cost plus what the gear cost; units with no recorded cost count at no cost.
    - c. A sale made while you were away (`away = true` on the sale record): a sale first known from its mail when
       that mail was sent before the session started (sent = now − (30 − days left) days), or a sale seen sold at the
       first read of your auctions since the session started whose money is due less than an hour after the start
       (the money comes about an hour after the sale, `Gold.MAIL_DELAY`; not measured on Forever).
    - d. The deposit given back: a sale's mail money beyond the sale after the cut is kept on the sale (`back`,
       `backAt`, `Ledger.SalePaid`), measured from the mail, not assumed.
    - e. The statement (`Statement.Compute`) for a time `from`..`to` (both included) of one character:
       Sales = Σ net (after the cut) of sale records booked in the time, not away; Cost of what you sold = Σ their
       booked cost; Deposits lost = Σ deposits of the lost records (expired, cancelled); Cancel fees = the journal's
       "cancel" kind. Trading profit = Sales − Cost − Deposits lost + Cancel fees (which are negative). Sold while
       you were away = Σ (net − cost) of the away sales. Stock change = (v − c) at the end − (v − c) at the start:
       the end is the stock now while the time runs to now, else the last snapshot at or before `to`; the start is
       the last snapshot at or before `from`, else the first one in the time ("since <date>": the start is not
       known), else none ("not known"). Total = Trading profit + Sold while you were away + Stock change. Gold not
       from trading = the journal's kinds other than buy, sale, deposit, cancel and other auction house, by kind.
    - f. Check against your gold: gold at the start (`Journal.Summary` start) + money in the mail at the start →
       gold at the end + money in the mail at the end. Money in the mail just before a time t (`Statement.MailAt`) =
       Σ net of sales booked before t and paid at or after t (unpaid ones: their unpaid units). Change in gold and
       mail = (gold + mail at the end) − (gold + mail at the start). Explained = all sales of the time (away ones
       too) + deposits given back + gear bought + deposits paid + cancel fees + other auction house + gold not from
       trading (the last five from the journal). Not explained = change − explained; 1s or less counts as none
       (grey), else it shows in orange with "!" and a tooltip: a record is probably missing. The brief named "sales
       collected"; with the mail on both sides that would count the money in the mail twice, so the sales booked are
       used (they go into the gold or the mail).
    - g. Words and colors: no trading jargon in the statement; every line has its help on hover (`row.tip` of
       `Widgets.List`) and reads without it. Green or red only for real gold (Trading profit, Total, Gold not from
       trading, Change in gold and mail, each change of gold); the stock's change is green or red too (0.3.133; it was grey as it rests on today's prices).
    - h. Layout (0.3.126, the user: "align the table to the right like a regular statement"; UI.md Statements, from
       established practice): a two-line heading, what it is and for whom ("Gold statement of <character>"), then the
       period ("This session: 11-26 18:49 to now (1 h 10 min)", a past session, a range, or "All time: every record
       kept"). The label column takes the free width and the amount column ends at the table's right edge
       (`cols.statement` in `Widgets.List`; `list.amountsRight`). Sections are heading rows with the gold band and no
       amount: Trading; How much richer you are; Gold not from trading; Check against your gold; What your records
       explain; Not explained; Sessions (72). Their lines are one step in (14 px); each total is at the heading's level,
       in bold (12 pt, `row.bold`; its width measured at 12/10 of the small font), with a rule over the amount
       (`row.rule = "total"`); the bottom lines (Total: how much richer you are, the statement's; Not explained, the
       check's) have a double rule under them too (`"final"`). No "=" lines (0.3.123 had them). Every total is the sum
       of the lines above it since its heading, so a total used again is carried down as a line ("Trading profit, from
       above"; "Change in gold and mail, from above", "Less explained by the records"), and the balances of the check
       are signed lines (gold and mail at the end +, "Less gold at the start" -). One sign rule on every amount: + came
       in, - went out (zero has none). Amounts show every coin under the largest one with two digits
       (`ns.MoneyColumn`, `Util.FormatMoney(c, icons, true)`: "12g 05s 00c"), so the coins line up; the other Reports
       tables use the same form (UI.md Tables 9). The hyphen is the minus sign: the game font's U+2212 is not known to
       exist. The Reports tables' totals row (Profit, Materials: "Total", was "All" at the top) is the last row with a
       line over it, in bold (Tables 13); all Reports rows are 22 px, as the other tables (was 20).
    - i. Limits: the ledger is account-wide and the gold journal per character, so another character's sales show
       as Not explained; a sold auction's mail delay is a guess; Clear history removes the records older statements
       are built from (the closed sessions keep their Trading profit and Total once shown).
98. **Windows can go partly off the screen** (0.3.124, the user, 2026-11-26), to get them out of the way. Every
    movable window (`Widgets.Window` and the main window) stays clamped to the screen, but its clamp rect
    (`Widgets.ClampToTitle`, `SetClampRectInsets`) is turned inside out: its left edge 40 px left of the window's
    right edge, its right edge 40 px right of the window's left edge (`Widgets.ON_SCREEN`), its top the window's top,
    its bottom 24 px under it (`Widgets.TITLE_H`). So a window goes off the left or the right side until 40 px of its
    title bar are left, never above the top, and down until only its title bar is left. Made again on every size
    change (`OnSizeChanged`, the width fit of 91 included). Places are kept as before. `/salv windows reset` puts
    every window at its default place (`Widgets.ResetWindows`: the center, the main window 200 px right of it where
    the screen has room), built or not, and says so in the chat; the "Salvager" button on the auction house is not
    a window and keeps its place. Not yet seen in the client: the client clamping an inside-out rect edge by edge is
    assumed (the frame API documents the insets, not this case).

99. **Result rates from your own disenchants** (0.3.125, the user, 2026-11-26). Per band (quality, gear type, item
    level band) and Salvager state (`salvager` of the disenchant record), the forecast blends your results with the
    table as a prior (`Model.Blended`, `Ledger.Results`, `ns.Outcomes`): the table counts as `Model.RESULT_PRIOR` = 50
    disenchants. Each (material, quantity) gets the weight K × the table's chance of the material × the table's chance
    of that quantity (min..max equally likely; with the Salvager, dust and essence one more with `salvagerChance`),
    plus the times you got it. A material's rate = (K × table rate + your hits) ÷ (K + your disenchants); its
    quantities follow the same counts (a Dirichlet with the table as its mean); a material the table does not have
    comes in with your hits only. With no results the blend is the table, to the copper. Expected value
    (`Model.Value`: chance × mean quantity × unit value), buy limits, Deals, Loss chance (`Model.LossChance`: each
    quantity's own chance), the Odds, the Market's disenchant value and a disenchant's `planned` value use it, with
    your results with the Salvager when buying counts its bonus and without it otherwise. Cautious pricing still
    takes the table's lowest amount. "few results" under `Model.FEW_RESULTS` = 50 of yours (the table still weighs
    more). Measured 2026-11-26 on the user's data, at the saved prices, Expected value table → blend: Uncommon Armor
    26-30 with the Salvager (251) 1631 → 1634 c; without (50) 1292 → 1233 c (−4.6%: essence 10% of the time, table
    20%); 31-35 without (31) 1437 → 1459 c; the other bands under 15 disenchants move 0.3% to 2.5%. Loss chance at
    the buy limit moves at most 3 points. Limits: results are not judged for their Salvager state beyond the record
    (a result above the table marks it "with Salvager", 74b, which leans that side up a little: 10 of 266).
100. **Time to sell and Return per day** (0.3.125, the user, 2026-11-26). Time to sell of a material
    (`Ledger.TimesToSell`, `ns.TimeToSell`): from the post to the sale, the median by units of its sales of the last
    30 days, pulled toward all materials under 5 sales (as the sell price ratio, 3). The post is the sale's
    `postedAt` (kept from 0.3.125 when a sale is seen sold, from `SalvagerDB.posted`), else the last post of that
    material at that price each before the sale; sales of posts not made through Salvager do not count. The sale is
    at its money's due time less `Ledger.MAIL_DELAY` (1 h) when known, else when it was booked (a sale known from its
    mail only counts late). Unsold posts do not count, so it is the time of what sold. Shown in the Materials list
    (35) and the material's tooltip. Return per day of a deal (`Model.DaysToSell`, `Model.ReturnPerDay`,
    `Scanner.ReturnPerDay`): Return ÷ days, days = the time to sell of the band's materials weighted by their part of
    the Expected value, at least 1 day. In the deal's tooltip with that time, not a column: on the user's data
    (2026-11-26, 91 of 98 sales matched to a post) materials sell in minutes (median 1.4 min over all, Soul Dust 1.4 min
    over 36 sales, Large Glimmering Shard 3.3 min over 7; the slowest sales took 1 to 4 h), so every deal counts 1 day and
    Return per day equals Return; a column would repeat Return (UI.md Tables 1). The deal sort stays as it is (73).
101. **One order and one look for every window** (0.3.128, the user, 2026-11-26: "Menu tabs first, then subtabs,
    then filters"; UI.md Controls). From the top: title bar with the close button; tabs (`Widgets.Tab`: the game's
    `PanelTopTabButtonTemplate` where the client has it, else a flat tab, the selected one lighter with gold edges
    and joined to the content); subtabs (`Widgets.Subtab`: text with a gold line under the selected one); the
    view's filter row (`Widgets.Dropdown`: `WowStyle1DropdownTemplate` where the client has it, else a dark field
    with the game's dropdown arrow; each with its label at its left); the content; the footer (status left,
    actions right, Cancel last). Rows are `Widgets.Bar`s; every control carries `uiKind`, which the layout dump
    writes (`k=`) and `make layout` checks (UI.md Controls 14). Per window:
    a. Main: tabs Gear and Materials (Deals until 0.3.129; Limits is a window now). Gear: a "Scan settings" block
       (heading, the Scan, Buy and Levels rows; Scan once: Gear, Materials, Both from 0.3.129), then the list. Materials: a filter row ("Only materials with my data"; Scan owned and
       Pop out at its right end), then the list. Footer: two lines of text (the last scan and the closest item at
       the left; the status and the gold at the right of line 1, the next item to buy at the right of line 2), and
       a row of buttons: Auction house, Ledger, Reports, Market, Limits, Log, Options at the left; Play, Stop and
       Buy Top at the right. Nothing on the tab row but the tabs (the gold, the pop-out and the window buttons left
       it).
    b. Limits window (`LimitsWindow.lua`, new): the table of the old Limits tab (columns "Armor: recommended",
       "Armor: limit used", "Weapons: recommended", "Weapons: limit used"; the limit boxes over the "limit used"
       cells); footer: cautious pricing note at the left, "?" at the right. Kept open with the others (24).
    c. Ledger: tabs; subtabs (Sales: Open and sold, History; Purchases: All purchases, Not picked up); the filter
       row (Purchases' first subtab: Search, Gear, Quality, Bands, Not disenchanted; Accuracy and Odds: Gear,
       Quality, Bands, Salvager; Odds also "Only bands with my data"); the tables; footer, two lines (0.3.130: one line
       cut the totals in Sales): the totals line with its chart button, the whole width; under it, at the right, the
       view's part: Check undercuts and Cancel undercut (Sales), the bag
       space (Purchases), Pop out (Odds). The totals line was above the tabs, the pop-out next to the Odds tab, the
       undercut buttons and the bag space on the subtab row.
    d. Odds window: two filter rows under the title bar (the filters; "Only bands with my data"), then the cards.
    e. Materials window: filter row ("Only materials with my data", "?" at its right end); footer: status at the
       left, Scan owned and Scan materials at the right (they were on the top row).
    f. Market: tabs; filter row "Time"; the list and the chart (the Time dropdown was on the tab row).
    g. Reports: its tabs, Gold subtabs and filter row on the same widgets (the order was already right, 0.3.126).
    h. Log: filter row "Lines" (a dropdown; it was a button that cycled); footer: the count at the left, Clear at the
       right.
    i. Post: footer: Undercut lowest and Break-even at the left (under the price), Post then Cancel at the right end.
    j. Breakdown, Stand, Options: no tabs or filters; unchanged. Every window closes with Escape (`UISpecialFrames`)
       and has the close button at its top right.
102. **Gear details window** (0.3.129, the user; `GearWindow.lua`, "Salvager Gear Details"): a click on an auction's
    row in the main window's Gear tab (a single auction, or a row inside an opened group; a group heading still
    opens and closes) shows that auction; a click on another row replaces it. Fixed width (620), the height is the
    player's, its place remembered, Escape closes it, it closes with the main window. Content, a report from the top:
    the heading (icon, the link with the game's tooltip on hover; quality, gear type, item level, band; "this
    auction, as of the last scan"); "The deal" as a statement (Expected value of one disenchant +, Buyout -, Expected
    profit as the bold total, green or red like every signed amount, 0.3.133); "Return and risk", one row (Return, Loss chance, Buy limit, Limit set
    by: Min profit, Min return, You (Limits) or Max price; Time to sell, Return per day); "How the Expected value is
    built" (`Model.ValueBuild`: one row per result with Rate used, Quantity used, Value each = price × sell price
    ratio after the cut less the deposits lost per unit sold, Part of the value = their product; the total "Expected
    value, now" last; the title says how many of your disenchants of the band the rates rest on, "few results", with
    or without the Salvager, and when prices moved since the scan); "Your history with this gear and its band"
    (`Ledger.Profits`, all time: Disenchanted, Paid, Sold value, Profit, Return); "Other auctions of this gear in
    the list" (Buyout, Expected profit, Under the limit by, State). Footer: Buy (the row's path, `Scanner.Buy`, the
    mouse on it holds the scan; off with the reason: being bought, gone from the list, auction house closed, not
    enough gold) at the right, Close last. When a scan replaces the auction's row, the window follows it by auction
    ID; when the auction leaves the list, the window keeps showing it (UI.md Actions 4) and Buy says why it is off.
103. **Headings that open and close, one way** (0.3.129, the user; UI.md Tables 15): every table with groupings:
    the main window's gear groups (they start closed), Reports' Gear Bands, Market's Disenchant value, Breakdown's
    bands, the Limits window's qualities, Ledger Purchases (start closed), Accuracy and the Odds cards. An arrow at
    the left of the heading (`Widgets.GroupArrow`: the game's gold arrow, right = closed, down = open; it was a plus
    or minus sign), the whole heading row is the click target with the hover highlight (a heading card's whole
    title band), a closed heading keeps its totals. `ns.HeadingToggle(row, state, key, changed, closedFirst)` sets
    the row's `open` and `onClick`; `ns.GroupedRows` uses it; the state is saved per table in
    `SalvagerDB.groups[<table>]` (`ns.GroupState`: "main.gear", "reports.bands", "market.value", "breakdown.bands",
    "limits"; Accuracy, Odds and Purchases keep theirs in their filters, as before).
104. **Gear and materials** (0.3.129, the user; UI.md Words 1): what the player buys and disenchants is "gear"
    everywhere he reads it (window titles, tabs, columns, help, tooltips, chat, slash help, README); "item" stays
    for a game item in general and in "item level"; what a disenchant gives is "materials". Window titles are
    "Salvager <Name>", the name capitalized (UI.md Layout 10): Salvager Ledger, Reports, Materials, Market, Log, Odds,
    Options, Breakdown, Limits, Post, Stand, Gear Details. The log keeps "item <ID>" in its lines (the Log window
    shows the name in its place). Expected profit and Return in the Gear list: the one the list is sorted by
    (it drives Buy Top and the order) is green when it gains, red when it loses; since 0.3.133 the other too (0.3.132, the
    user: 0.3.129 made both grey). The same in the row's and Buy Top's tooltips. A click on the gear above Buy Top
    opens its Gear Details, as a click on its row does.

## Data

`SalvagerBackup` (account-wide): `list` of ledger copies (88). `SalvagerDB` (account-wide): `settings`, `prices`, `ledger` (`purchases`, `stock`, `pools`, `disenchants`, `sales`),
`money` (gold journal), `sessions` (97), `quality` and `ilvl` (learned item data), `auraSeen` and `auraSnapshots` (to learn the Salvager's aura spell ID; matched by name until then).

## Open

1. Whether Boosted Disenchanting (1283701) stacks with the time spent near the Salvager, and whether the
   bonus grows with it: read `salvagerStacks` and the results after the next batches (74b).
3. The shape of the Salvager bonus (74a): neither dust nor essence looks like "+1 half of the time"; essences get
   about half the dust's bonus (0.3.125). The blend (99) follows the data per band; check the shape after about 100
   more disenchants with the Salvager outside Uncommon Armor 26-30.
2. Whether Forever's disenchant results match the Classic table: the Ledger window (Odds) compares observed odds per band.
