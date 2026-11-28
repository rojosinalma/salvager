# Salvager — design decisions

## Scope

Public WoW Forever addon (interface 16001), on CurseForge under the MIT license (89). Buying and selling at the auction house only; vendor
flipping is out of scope for now.

## Decisions

1. **Disenchant table by item level** (Classic table). Required level is only a rough guide; the auction
   house's level filter uses required level, but every item key carries its item level, which picks the band.
2. **Arcane Salvager rule:** 50% chance of one extra dust or essence; never on shards or single fixed
   results. Source: a community spreadsheet with 7000+ disenchants. Configurable (`salvagerChance`, Options
   "Starting chance of one extra dust or essence (%)"). Since 0.4.0 it is the prior of the learned Salvager shape
   (118), not the rule itself: your results with the Salvager take over as they grow.
   Applied to buy prices only when the player can use it (recipe spell 1263056 or item 279985), or by
   `/salv salvager on|off`.
3. **Material price and what a unit sells for** (rewritten 0.3.122, the user, 2026-11-26). The material's price
   (its value) = average unit price of the cheapest 20 units, own listings excluded. When a scan finds none, the
   last price stays in use (marked `*`) for one day at most (67). A missing essence price is filled from the other
   form (3 lesser = 1 greater, marked `~`). The price itself stays the market's; what the forecast counts a unit at
   is price × the material's **sell price ratio** (`ns.SellRatio`, `Ledger.SellRatios`): what one unit of it
   really sold for (the sale price each, before the cut) against its price when that auction was posted. Per
   material, the median of its sales weighted by units × the sale's weight by age (118; until 0.4.0: the sales of
   the last 30 days, by units) (`Model.WeightedMedian`); n = the weight of its sales; under 5 it is pulled toward
   the median of all materials, (n × own + (5 − n) × all) ÷ 5 (`Model.Blend`), and the median
   of all toward 1 the same way; no sales at all = 1. The price at the post is recorded from 0.3.122 on
   (`SalvagerDB.posted[].val`, copied to the sale as `val`); older sales take the price history (57) at the
   post of that material at that price each made before the sale, else at the sale. Used in the Average value of
   gear (`Model.Value`, `ns.ValueOptions`; with the result rates of 99) and in each whole-unit outcome's value (116),
   so in buy limits (`Model.MaxBuy`), the Gear list, Lose %, Odds, the
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
7. **Sales** are recorded from the "Auction successful" invoice: net = sale − cut (replaced by 40: a sale is booked
   when your auctions list shows it sold, and the invoice marks it paid and books only units never seen). Deposits
   lost on expired or cancelled auctions are tracked (70d) and counted in the forecast (96).
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
23. **Clear history** (Ledger window until 0.3.106; in the Options since, 88; with a confirmation) removes disenchants, sales and the purchase record.
    Stock and its costs stay; purchases not disenchanted yet stay, except items that can never be disenchanted.
24. **Layout is remembered.** `SalvagerDB.windows[key].open` is set only by deliberate actions (the addon's
    buttons and commands, a window's X). Escape and the auction house closing hide every window at once and
    do not change it. When the auction house opens (and `autoOpen`, `restoreWindows` are on) the Ledger, Log
    and Materials windows that were open are shown again (now every window that was open: also Market, Reports, the
    Odds pop-out and Limits, `UI.RestoreWindows`, 78). The main window's tab and the Ledger's view are
    kept too.
25. **Searches that get no answer** (measured 2026-11-25, 0.3.3 to 0.3.8): about one item search in four got
    no answer on its first try and none of them reported a drop; every second try worked. Cause not known
    (another addon sharing the one-request lock is the main suspect). Since 0.3.9: the wait is 2 s, a search
    is tried up to 3 times and stays next in line, the `_ADDED` result events also count as answers, and at
    the timeout the results are used if the game holds them. A refresh with no new answer uses the held
    results and logs it. Each round logs its check time and both counts. Since 0.3.142 the wait is 3 s (measured
    2026-11-27 04:00–04:16: of 20 searches sent again after 2 s, 14 were answered within 1 s of that, mostly items
    with 100+ auctions, so the second request was waste), and an answer that comes while the search waits to be sent
    again is used ("came late, not sent again").
26. **Buying first.** Purchases on their way are kept per auction ID (a fast run of Buy clicks used to
    overwrite the one being tracked, so 2 of 19 purchases were recorded only from their mail, 2026-11-25).
    While a purchase is on its way, or Buy was clicked in the last second, the search queue waits and a
    reported drop is not answered with a resend: the dropped request may be the purchase. (Since 0.3.134 also while
    a click waits: 105. The hold for the mouse position of 0.3.134–0.3.141 is gone, 105b.)
27. **The Post window** is a window of its own (`Widgets.Window`, fixed size), not pinned to the main window.
28. **Value is an average; Lose % is the chance for one item** (since 0.3.152 the average is labelled as one and
    the deal shows its whole-unit outcomes and range, 116). Deals show `Model.LossChance`: the chance that
    one disenchant is worth less than the price (quantities equally likely, Salvager bonus included when on, a
    material without a price worth nothing). Example measured 2026-11-25: Azure Silk Hood at 11s 46c, value
    12s 57c, lose chance 75% (every dust result loses). The Odds (the Ledger's view until 0.3.148, a Reports tab since, 114) list every band of every
    quality and gear type with the table, today's value and the player's own results where there are any.
29. **Your auctions** (`Listings.lua`). Read on every `OWNED_AUCTIONS_UPDATED` (whoever asked), asked for at
    auction house open and after a post or cancel, kept in `SalvagerDB.listings` so the Ledger shows them
    with the auction house closed ("as of"). A sold auction's `timeLeftSeconds` is the wait for its money.
    Price each: the unit price of a post made through Salvager is known for sure (`SalvagerDB.posted`); if a
    listing's reported price equals that times its quantity, this client reports totals and the rest are
    divided. Undercut = the lowest listing that is not yours is below your price each (one commodity search
    per listed material). Cancel needs a click per auction (`CancelAuction` is hardware-event restricted) and
    loses the deposit; searches wait while a cancel is on its way (not the read of your auctions, which tells the
    cancel: 0.3.138; before, it waited the cancel's 8 s and the cancel cost was lost from its record). Not verified in
    the game yet.
30. **Odds filters:** quality and gear type, kept with the Ledger window (with the Odds window since 0.3.148, 114).
31. **Odds columns:** each band row shows Buy below (`ns.BuyLimit`: the hand-set limit, else value minus the
    minimum profit) and Lose % at that limit (`Model.LossChance` with the limit as the price: the risk when you
    pay the full limit; "-" when the limit is 0). Titles: Expected (the table), You got, Value now, Buy below,
    Lose %, Your average. `Widgets.List` columns take `help = { title, text }`, shown over the column title.
    0.3.125: each material row also has Rate used and Quantity used (the blend of 99, grey with "(few results)" under
    50 of yours), and the card's facts end with "Rates used from" (your disenchants the blend rests on, with or
    without the Salvager as buying counts it; the filters do not change it). Buy below and Loss chance use the
    blend. `Widgets.CardList` makes 10 cells a row (was 8).
    The lose colors are in one place (`ns.LoseText`), shared with the Gear list.
    (Replaced: the columns and facts of 114d-e (0.3.148) and the average names of 116g (0.3.152).)
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
    with its own title, columns and scroll bar (Open auctions and Sold since 0.3.108, 64). The Log stays a plain text list.
39. **Odds view: one table per band** (`Widgets.CardList`): a scrolling stack of cards, each a sunken panel
    with a gold title band (the band, then its facts: disenchants, value now, buy below, lose, your average),
    column titles and one striped row per material. Cards and rows are created as needed and reused. 0.3.148: two
    per row, the facts and columns of 114.
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
    0.3.148: Sales, Purchases, Accuracy; the Odds are a Reports tab and pop out from there (114).
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
50. **(Replaced 0.3.99 by 83: the Gear filter; 0.3.148 Armor and Weapons headings, 114c.) Odds subtabs:** Armor and Weapons, one at a time (`windows.ledger.oddsTab`); they replace the gear type
    filter. Band names are written "Uncommon Armor", "Rare Weapons".
51. **Odds band filter:** the scan's item level bands as ranges (`windows.ledger.oddsBandsOff`; with the Odds'
    other filters in `windows.odds.filter` since 0.3.148, 114b); a rare or epic band shows when it overlaps a ticked range.
52. **Sales tables share their height by a draggable bar** (`windows.ledger.salesSplit`, 0.1 to 0.9, default
    0.45; right-click resets). Since 0.3.147 the same bar (`Widgets.SplitBar`) is in every view with two tables (113d).
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
    `SalvagerDB.history` (price, lowest listing, units listed; one point per minute, `History.SLOT`, at most 1000 per
    material, `History.MAX_POINTS`: past it the older half keeps every second point; it was one per 10 minutes, 600).
    The window charts one material: price and lowest listing as lines, your break-even as a level, units
    listed as bars; ranges 6 hours, 24 hours, 7 days, all.
58. **Window sizing:** Ledger and popped-out Odds have a fixed width and a free height (`Widgets.Window`,
    `fixed = "vertical"`); Materials fits its content; the main, Log, Breakdown and Market windows are free. Each
    view sets the width again (113).
59. **A round only removes what it has read.** Deals leave the list when their quality and gear type was
    browsed in full and the item is no longer under its limit. A browse that did not load in full (measured
    2026-11-26: "0 items in 0 pages, no page for 4s, given up") leaves that pass's deals as they are. A browse
    with no first page is sent again (twice) before it is given up.
60. **Market views:** Materials, Disenchant value (the band's value at each moment a material price was seen,
    with the last known price of each material, against the buy limit now), Profit (sales with a known cost,
    added up, and per day), Essences (3 lesser against 1 greater), By hour (average price per hour of the day; "Time of day" since 81).
    The history is filled once from older data (`Prices.SeedHistory`): last scans, log, disenchants, posts.
61. **Accuracy view** (Ledger, `Ledger.Accuracy`): per band and in total, over disenchants with a recorded
    purchase: Paid, Promised (value shown when bought), Got (value at the disenchant), Sold for (the same
    materials at the average price each really sold for; at the disenchant's price where none sold yet), and
    the planned and real profit. A second table per material: valued each against sold each. Sales are not
    tied to items (pooled stock), so "Sold for" per band is an estimate. Column names (0.3.117, the user: the
    window was too wide; abbreviations, UI.md Words 2): By band `Band | Disenchanted | Paid | Expected value (EV) |
    Disenchant value (DV) | DV/EV % | Sold value (SV) | SV/DV % | Expected profit (EP) | Actual profit (AP) | AP/EP %`;
    By material `Material | Units | Disenchant value each (DV) | Sold value each (SV) | SV - DV | SV/DV % | Units sold`.
    (0.3.152: Expected value (EV) and Expected profit (EP) are Average value (EV) and Average profit (EP), 116g.)
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
64. **Sales view:** two subtabs (a third, Competition, since 0.3.138, 109). "Open and sold" has two tables: Open auctions (only what is still for sale)
    and Sold (sales whose money is not collected yet, with a countdown). "History" lists the sales whose mail
    was taken. The game keeps a sold auction in its own list until the money is mailed; the addon shows it
    as a sale, not as an auction.
65. **A Buy click always buys** (the user's rule: a deal is lost if it waits). Nothing ever asks the player to
    wait or click again. With the auction house free the purchase is sent in the click. With it busy
    (`IsThrottledMessageSystemReady` false) a purchase sent now is lost with no answer and no event (measured
    2026-11-26, 03:17: five such clicks, "no answer in 10s"), so it is sent on the next
    `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`, ahead of the whole queue, one purchase per "ready" (only while the game
    allows a purchase without a click; with `buyResendBlocked`, the click waits and its Buy says "Buy now", 105). To
    keep the line free, the scan holds while a purchase is on its way or a click waits (105; the hold for the mouse
    position, 0.3.134–0.3.141, is gone: 105b). A purchase the auction house reports as dropped is sent again by the addon when the
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
    Limits tab marks a limit set by the return with "%"; for an inferred band the value is the pessimistic one, 116d).
    Deals have a Return column (Avg return since 0.3.152, 116e) (expected profit ÷
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
       0.4.0 (118): the shape is learned per material kind from every band; on the saved data of 2026-11-27 Soul
       Dust and the other dusts 1-2 with the Salvager come as 1 / 2 / 3 about a third each (35.9 / 30.1 / 34.0% of
       454), essences 39.1 / 37.4 / 23.5% (115), shards always 1 (31).
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
       it waits for its answer or for 10 s (3 s since 0.3.134, and said in the chat: 105). (06:31: every purchase was freed with "click Buy again" and
       went through; the extra clicks then gave "could not buy".)
    - c. An "open all" takes several mails before the gold is read: one change of gold is matched to the
       first expectations, in order, that add up to it (8g 40s 75c from 5 sales mails at 13:28).
    - d. `make install` checks the version on the gaming PC after the copy (0.3.86 did not arrive the first time).
78. **The main window leads** (2026-11-26, the user): when it closes, every Salvager window closes with it
    (hidden, not marked closed: `UI.HideOthers`; since 0.3.137 only the windows it opened, 108c), and they come back with it (`UI.RestoreWindows` on its
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
    statement's first line, the help is on the tab. Width at least 890 (was 760), so the longest filter row fits
    (1050 since 0.3.145, with the search, 111).
    Views (tabs, 0.3.129: Gold, Gear, Materials; Competition since 0.3.138, 109): Gold (72, 97);
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
    "Uncommon 26-30" (until 0.3.148: since, under the gear type and quality headings, titled "26-30", 114c). A sorted grouped list sorts inside each group (`section`, `head`). `/salv report` too
    (Armor, Uncommon 26-30: ...). The main window's Limits tab (the Limits window since 0.3.128, 101b) is a table of two halves instead (the user,
    0.3.97): an Armor title over its Recommended and Override price threshold columns, a Weapons title over
    its two; the rows are the bands of every quality (whatever the scan looks at; grey where it does not),
    under a heading per quality, the range only. Vertical lines after the Item level column and between the
    halves (`groupHeader`, `dividers` of a main window view).
82. **Ledger Purchases** (0.3.96): one row per item (newest first) with its count and totals; a click opens it
    to show each purchase with what it gave (`purchaseFilter().open`). A search box (any part of the name,
    any case) and filters by gear type, quality and item level band sit on the row under the tabs; all kept
    in `SalvagerDB.windows.ledger.purchaseFilter`. (0.3.98) The open / close sign comes first on the row,
    18 px, before the item's icon (`data.open` of a `Widgets.List` row); a "Not disenchanted" check box showed
    or hid what is bought and not disenchanted yet (the Show dropdown since 0.3.136, 107); a click on a column title orders the items by it (again
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
    names in use (Recommended / Override price threshold; Expected value, Expected profit, Return; since 0.3.152 "Profit:
    low - avg - high" and Avg return, 116e).
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
    two lines sit over the footer's row of buttons; the status and the gold at the right of line 1. 0.3.134: the gold
    moved to the row of buttons, left of Play, 101a.)
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
    tags `v<version>` and pushes the tag to GitHub (`origin`); the changelog is the version's section of
    `CHANGELOG.md` (written for players; since 0.4.0), else the commit subjects since the last tag. Each upload is a new
    version: it refuses a dirty tree or a version already tagged. Local settings (install host, AddOns
    folder, CurseForge token and project) live in `.env`, never in the repo. Forever only: the file gets one
    game version, of the Forever type (`CURSEFORGE_GAME_VERSION_TYPE=88568`), and the TOC has only interface
    16001, so other clients do not load it. Blizzard's own Forever TOCs have no flavor suffix, so neither does ours.
90. **Purchases view: two subtabs and the bag space** (0.3.108, the user; a third, Current batch, since 0.3.136,
    107). "All purchases" (first) is the list as before (by day and status since 0.3.136, 107), with its search and filters on the filter row under the subtabs. "Not picked up (n)" lists the
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
    0.3.136: at most the screen's width (`Widgets.ScreenWidth`, UIParent's width); the other windows fit too (107).
92. **The version in the title bar** (0.3.110, the user): every window made by `Widgets.Window`, and the main
    window, shows `v<version>` (`ns.VERSION`, from the TOC through `C_AddOns.GetAddOnMetadata`) at the left
    end of its title bar (`f.TitleBg`), small and dim (`GameFontDisableSmall`). Where it would come within
    12 px of the centered title at the window's smallest width, it is left out (`Widgets.TitleVersion`).
93. **Buy Top** (0.3.111, the user; 0.3.112; "Buy Top" since 0.3.129): a button at the bottom right of the main
    window, left of the resize grip, on every tab. One click buys the single best auction of the Gear list by the
    active sort, from any row
    (`UI.TopDeal`): of every auction not being bought, the one with the highest Average profit (profit sort) or
    Avg return (return sort; named Expected profit and Return until 0.3.152, 116), each auction's own (`d.profit`, `Scanner.Return`); ties go to the other number, then the
    lower buyout, then the auction ID. Not the top row: after the best auction of a row of several is bought, the
    next click can buy another item's auction before that row's dearer ones (0.3.111 followed the row, a fix of
    the user's intent in 0.3.112). The list does not move. When the gold is short for the best auction, the click
    buys the best one the gold covers, and the tooltip names the skipped one. It goes through `Scanner.Buy`, as a
    row's Buy: the click is the hardware event, the scan holds, a busy auction house gets it as soon as it is
    ready (65); while it is busy, "..." and off, the click does nothing (105j). Off, with the reason in its tooltip: auction house
    closed, no gear scan yet, the list empty, every deal being bought, not enough gold for any (the best one is
    named). Its tooltip shows the gear and the deal's lines of what the click buys (`UI.AddDealLines`, as a Gear
    row's: Item level, Buyout, Expected value, Expected profit, Return, Loss chance, Time to sell, Return per day;
    since 0.3.152 the outcomes and averages of 116f),
    (0.3.134, 105: while a click waits for the auction house, Buy Top is for that auction, "..." and off with the
    reason, then "Buy now", lit; 0.3.142: "..." with the reason while the auction house is busy, 105j),
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
    sold over the last 30 days (since 0.4.0 every sale, weighted by age, 118a), as a share `k` of the deposit of one unit in one post (`Ledger.DepositRates`;
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
    comes in with your hits only. With no results the blend is the table, to the copper. Average value
    (`Model.Value`: chance × mean quantity × unit value; the mean quantity is an average, never shown as an outcome:
    the outcomes are whole units, 116), buy limits, Deals, Loss chance (`Model.LossChance`: each
    quantity's own chance), the Odds, the Market's disenchant value and a disenchant's `planned` value use it, with
    your results with the Salvager when buying counts its bonus and without it otherwise. Cautious pricing still
    takes the table's lowest amount. "few results" under `Model.FEW_RESULTS` = 50 of yours (the table still weighs
    more). Since 0.4.0 (118): your results are weighted by age (n, hits and quantities are weights, `count` the
    disenchants), and with the Salvager the table's quantities of each result follow the learned Salvager shape of
    its material kind in place of "+1 with `salvagerChance`"; "few results" and observed (116c) use the weight. Measured 2026-11-26 on the user's data, at the saved prices, Expected value table → blend: Uncommon Armor
    26-30 with the Salvager (251) 1631 → 1634 c; without (50) 1292 → 1233 c (−4.6%: essence 10% of the time, table
    20%); 31-35 without (31) 1437 → 1459 c; the other bands under 15 disenchants move 0.3% to 2.5%. Loss chance at
    the buy limit moves at most 3 points. Limits: results are not judged for their Salvager state beyond the record
    (a result above the table marks it "with Salvager", 74b, which leans that side up a little: 10 of 266).
100. **Time to sell and Return per day** (0.3.125, the user, 2026-11-26). Time to sell of a material
    (`Ledger.TimesToSell`, `ns.TimeToSell`): from the post to the sale, the median by units × weight by age of its
    sales (118; until 0.4.0 the sales of the last 30 days), pulled toward all materials under 5 (weighted) sales (as
    the sell price ratio, 3). The deposits lost per unit sold (96, `Ledger.DepositRates`) weigh the same way. The post is the sale's
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
    and joined to the content); subtabs (`Widgets.Subtab`: segments of a segmented control, a box with a grey edge and dark fill, the selected one gold fill and edge, a lighter fill under the pointer; until 0.3.134 text with a gold line, which the user found did not read as clickable); the
    view's filter row (`Widgets.Dropdown`: `WowStyle1DropdownTemplate` where the client has it, else a dark field
    with the game's dropdown arrow; each with its label at its left); the content; the footer (status left,
    actions right, Cancel last). Rows are `Widgets.Bar`s; every control carries `uiKind`, which the layout dump
    writes (`k=`) and `make layout` checks (UI.md Controls 14). Per window:
    a. Main: tabs Gear and Materials (Deals until 0.3.129; Limits is a window now). Gear: a "Scan settings" block
       (heading, the Scan, Buy and Levels rows; Scan once: Gear, Materials, Both from 0.3.129), then the list. Materials: a filter row ("Only materials with my data"; Scan owned and
       Pop out at its right end), then the list. Footer: two lines of text (the last scan and the closest item at
       the left; the status (the gold until 0.3.133) at the right of line 1, the next item to buy at the right of line 2), and
       a row of buttons: Auction house, Ledger, Reports, Market, Limits, Log, Options at the left (Disenchant after Market
       since 0.3.146, 112); Play, Stop and
       Buy Top at the right (Play and Stop one toggle since 0.3.137, 108b). 0.3.134 (the user): left of Play, two readouts (text, not buttons): the gold (coins,
       moved from the footer's upper line) and the bag space (`LedgerWindow.BagText`, the Purchases view's, with its
       help), each as wide as its widest value, live on `PLAYER_MONEY` and `BAG_UPDATE_DELAYED`. The smallest width
       is 940 (880 in 0.3.134, 800 before; 0.3.135: the gold readout sized for the gold cap, 214748g 36s 47c, and the bag space for three digits) so the row fits (`bar.used`). Nothing on the tab row but the tabs (the gold, the pop-out and the window buttons left
       it).
    b. Limits window (`LimitsWindow.lua`, new): the table of the old Limits tab (columns "Armor: recommended",
       "Armor: limit used", "Weapons: recommended", "Weapons: limit used"; the limit boxes over the "limit used"
       cells); footer: cautious pricing note at the left, "?" at the right. Kept open with the others (24).
    c. Ledger: tabs; subtabs (Sales: Open and sold, History, Competition (0.3.138, 109); Purchases: All purchases, Not picked up, Current batch); the filter
       row (Purchases' first subtab: Search, Gear, Quality, Bands, Show (the "Not disenchanted" check box until
       0.3.136); the third subtab, Current batch, since 0.3.136, 107; Accuracy and Odds: Gear,
       Quality, Bands, Salvager; Odds also "Only bands with my data"); the tables; footer, two lines (0.3.130: one line
       cut the totals in Sales): the totals line with its chart button, the whole width; under it, at the right, the
       view's part: Check undercuts and Cancel undercut (Sales), the bag
       space (Purchases), Pop out (Odds; the Odds left the Ledger in 0.3.148, 114a). The totals line was above the tabs, the pop-out next to the Odds tab, the
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
    the list" (Buyout, Expected profit, Under the limit by, State). Footer: Buy (the row's path, `Scanner.Buy`; off with the reason: being bought, gone from the list, auction house closed, not
    enough gold) at the right, Close last. When a scan replaces the auction's row, the window follows it by auction
    ID; when the auction leaves the list, the window keeps showing it (UI.md Actions 4) and Buy says why it is off.
    0.3.136: at least 620 wide, wider where its tables' columns need it (107; the Return of "Your history" was left
    out at 620 with long amounts). 0.3.152: "The deal" says Average value and Average profit, and "What one disenchant
    gives" (the whole-unit outcomes) replaces "How the Expected value is built" (116f).
103. **Headings that open and close, one way** (0.3.129, the user; UI.md Tables 15): every table with groupings:
    the main window's gear groups (they start closed), Reports' Gear Bands, Market's Disenchant value, Breakdown's
    bands, the Limits window's qualities, Ledger Purchases (start closed), Accuracy and the Odds cards. An arrow at
    the left of the heading (`Widgets.GroupArrow`: the game's gold arrow, right = closed, down = open; it was a plus
    or minus sign), the whole heading row is the click target with the hover highlight (a heading card's whole
    title band), a closed heading keeps its totals. `ns.HeadingToggle(row, state, key, changed, closedFirst)` sets
    the row's `open` and `onClick`; `ns.GroupedRows` uses it; the state is saved per table in
    `SalvagerDB.groups[<table>]` (`ns.GroupState`: "main.gear", "reports.bands", "market.value", "breakdown.bands",
    "limits"; Accuracy, Odds and Purchases keep theirs in their filters, as before). 0.3.136: Purchases' day and
    status headings (open first, `purchaseFilter().collapsed`) and Current batch's status headings ("ledger.batch",
    open first), 107.
104. **Gear and materials** (0.3.129, the user; UI.md Words 1): what the player buys and disenchants is "gear"
    everywhere he reads it (window titles, tabs, columns, help, tooltips, chat, slash help, README); "item" stays
    for a game item in general and in "item level"; what a disenchant gives is "materials". Window titles are
    "Salvager <Name>", the name capitalized (UI.md Layout 10): Salvager Ledger, Reports, Materials, Market, Log, Odds,
    Options, Breakdown, Limits, Post, Stand, Gear Details. The log keeps "item <ID>" in its lines (the Log window
    shows the name in its place). Expected profit and Return in the Gear list (the profit range and Avg return since
    0.3.152, 116e): the one the list is sorted by
    (it drives Buy Top and the order) is green when it gains, red when it loses; since 0.3.133 the other too (0.3.132, the
    user: 0.3.129 made both grey). The same in the row's and Buy Top's tooltips. A click on the gear above Buy Top
    opens its Gear Details, as a click on its row does.
106. **Specs that see a cut text** (0.3.135; UI.md Layout 6, Tables 2). The stand-in (`spec/wow.lua`, layout mode:
    `wow.install({ layout = true })`) models sizes, anchors, rects and text widths: a character is a share of the
    font size (Friz Quadrata, fitted to texts the client sized to their own text in the layout dump: 12 and 10 pt,
    within 8 %, each class rounded up about 4 %); color and link codes take no room, an inline texture is as wide as
    its size. `spec/fit_spec.lua` opens every window, clicks every tab and subtab, at the smallest and the default
    size with long data (9999g 99s 99c a unit, long gear names, every material, a full log), and fails on a cut text,
    two controls of a row that overlap, a text or a control outside its window, and a table (or an Odds card) whose
    last column does not end at its right edge (default size). A text that may be cut says so: `fs.canCut = true`
    (the first column of a table, "..." and the full text on hover; the main window's two status lines, cut at the
    next control). A table keeps its first column at least as wide as its text, up to 90 px: a column that would
    leave it less is left out, from the right (was: the first column down to 40 px, its text unreadable).
    `FIT_DEBUG=1` lists the columns left out. 0.3.136 (107): at the default size no table leaves a column out (on a
    1920 wide screen); at the smallest size one may, and then its note must show.

105. **Purchases during a scan** (0.3.134, the user, after nine lost clicks on 2026-11-26 23:29–23:30). Measured in
    the log of that day: 1 purchase of 147 went through when clicked after a gear scan had sent its browse and
    before the item was searched again; the clicks of 23:29:14–23:30:06 (during the Rare Weapons browse, and after
    it before Azure Silk Hood was searched again) got no answer, and every click after the hood's search at
    23:30:16 went through. So **a browse makes the item searches held so far stale: a purchase of an auction found
    before it gets no answer, no event.** (The client keeps a search per item: other items' searches do not.) A
    purchase sent while the auction house is busy is lost too (65). The game needs a click per purchase
    (`buyResendBlocked`, 74c), so nothing can be sent again for the player. The rules:
    - a. Every browse, ours or another window's (`SendBrowseQuery` hooked), adds one to `Scanner.browseEpoch`;
       each deal keeps the count of its search (`epoch`).
    - b. Where the mouse is holds nothing (0.3.142, the user: "Don't stop the scan while my mouse is over it").
       0.3.134–0.3.141 held every request while the mouse was over the Gear list, Buy Top or Gear Details
       (`Scanner.Aim`, 1 s after it left); measured in his log of 2026-11-27: Uncommon Armor 45 s (was 36),
       Uncommon Weapons 33 s (was 4.5), Epic Armor, one page, 29 s and 19 s, a browse of 658 listings 87 s, the 20
       gear checks 81 s (were 27–29). Now a new pass (`nextPass`), the next page, the stall watcher's resends,
       searches (gear, materials, your auctions, undercut checks), cancels and posts wait for `Scanner.Buying()`
       only: a click a moment ago (1 s), a click that waits for the auction house or its search, "Buy now"
       offered (20 s at most), a purchase on its way (g). A click during a browse buys through c–e.
    - c. A click with the auction house ready and the search current sends the purchase in the click.
    - d. A click on a stale deal does not send it: its item is searched first (`Scanner.Recheck(deal, true)`:
       first in line and past every hold); with the answer, its Buy says "Buy now" (lit) and the chat says
       "auction house ready: click Buy now for <gear>"; that click sends at once. Gone from the answer: the row
       goes, and the chat says so.
    - e. A click with the auction house busy (`IsThrottledMessageSystemReady` false) does not send it: the row
       says "...", everything holds, and at `AUCTION_HOUSE_THROTTLED_SYSTEM_READY` (or a check each tick) its Buy
       says "Buy now", as in d. Without `buyResendBlocked` the old automatic send stays (65).
    - f. The same on the row (a group's Buy is for its waiting auction), Buy Top (it is for the waiting auction
       first) and Gear Details. A wait is said in the chat when it starts; after 10 s without the auction house
       it is dropped and said; a "Buy now" nobody clicks lapses after 20 s, so the scan goes on.
    - g. A purchase sent with no answer in 3 s (was 10 s, without a word for that long) is said: "no answer yet
       for <gear>: click Buy again if it is still listed"; its row is free again and a late answer is still booked
       (`dropped`). Since 0.3.142 the auction house answers them in order, so only the oldest one's clock runs, from
       its click or the answer to the one before it, whichever is later (purchases answered 1 s apart are not called
       lost; until then one fresh purchase kept older ones from being given up at all, up to 11 "on their way"). An
       auction on its way is not sent a second time.
    - h. Every click is logged: ready or busy, aiming or not, search current or stale, and what is in flight (the
       search sent and its age, the browse pass and its pages, the last browse's age, purchases on their way), so
       the next failure can be measured. Not yet measured in the game.
    - i. Search on hover (0.3.140, the user: Buy Top cycled between "Buy now" and "Buy Top"): every click on a deal
       whose search a browse made stale needed two clicks (the search, then "Buy now", which lapses after 20 s
       back to the plain label). Now the deal under the mouse (its Gear row, Buy Top or the gear above it, Gear
       Details) is searched again the moment the mouse is there (`Scanner.Prefetch`, once per gear and browse, first
       in line past the hold), so the click that follows is on a current search and buys at once. "Buy now" stays
       only for a click faster than that search, or one while the auction house is busy. The search goes for the
       deal under the mouse anywhere over its row, Buy Top or Gear Details; it holds no scan (b).
    - j. Never sent while busy (0.3.142, measured 2026-11-27 04:00–04:16: 224 Buy clicks, 106 bought, 132 on a busy
       auction house, 30 of them on "Buy now" while it was busy again, and those were sent and lost). A "Buy now"
       click while busy sends nothing and stays "Buy now". Buy Top while busy (`Scanner.BuyBusy`) says "..." and is
       off, its tooltip "The auction house is still answering your last purchase" (or busy with another request),
       and a click then does nothing: no wait, no chat line, one log line per busy spell. Back the moment it is
       ready, so clicking Buy Top again and again buys one auction per answered purchase. A row's Buy keeps e.
    - k. Each scan's end (its gear checks done, or Stop) logs the time it waited for purchases by reason: "scan held
       for purchases: 4.2s (purchase 3.0s, waiting 0.2s, click 1.0s)" or "not at all" (`Scanner.holds`, counted
       each tick while a material or gear scan runs).
    - l. No search right after a purchase (0.3.144, the user: the checks after buying made more delays than they
       solved). Measured 2026-11-27 04:00-04:16: 110 such searches for 106 purchases; 111 of the 132 clicks that
       found the auction house busy came within 2 s after one. The bought auction leaves the list at once; its gear
       is searched again once, when no Buy was clicked for 8 s and nothing is on its way (also after a failed
       purchase).

107. **Purchases by day, the Current batch, windows that fit their columns** (0.3.136, the user, 2026-11-26).
    - a. All purchases: a "Show" dropdown on the filter row (after Bands) replaces the "Not disenchanted" check box:
       All gear (first), Disenchanted, Not disenchanted (`purchaseFilter().show`: "all", "done", "waiting"; a saved
       `hideWaiting = true` becomes "done" once). The empty table says why for the choice (nothing bought yet;
       nothing disenchanted yet; every piece disenchanted; nothing matches the search and the filters).
    - b. All purchases is grouped by the day the gear was bought (the disenchant's day where no purchase is
       recorded), newest first: a heading "Thu 11-26  12 pieces" with Paid and Expected value (Avg value since
       0.3.152, 116g) of all, Disenchant
       value and Profit of the pieces disenchanted. Under it a heading per status with its count and totals: "Not
       disenchanted" first (what the player acts on, UI.md Tables 4), then "Disenchanted"; one only shows when it has
       rows under Show and the filters. Under those the rows as before: one per item name (ordered by the column
       picked) that opens to each purchase with what it gave. Day and status headings start open, item rows closed
       (per day and status); all in `purchaseFilter()` (`collapsed`, `open`).
    - c. Current batch, the Purchases view's third subtab ("Current batch (n)"): the gear you bought and picked
       up and have not disenchanted, then the disenchants of bought gear whose materials are not all posted
       (`Ledger.Batch`). Purchases still in the mail are in Not picked up only (until 0.3.152; since 0.3.153 in
       the batch too, under "In the mail", 117). The rule: every post made through
       Salvager (`SalvagerDB.posted`: material, units, time) and every sale that came from no such post (posted
       another way: at the sale's time), in time order, takes that material's units of the disenchants made at or
       before it, first in, first out (a post before a disenchant is not its). Then what you hold caps it
       (`ns.HeldCount`: `GetItemCount`, bags and bank, less what the character wears, 0.3.141: worn gear is not in the batch): a material's units left, newest disenchant first, are at most what you hold
       (units converted, mailed or posted another way and not sold yet are gone with it); a gear's purchases left,
       newest first, at most the pieces you hold. A disenchant leaves when none of its units is left; a post that
       expires or is cancelled stays posted (its units come back as stock from elsewhere). Disenchants without a
       recorded purchase take part in the first in, first out but are not listed.
       Columns: Gear, Item level, Paid, Expected value (EV, at purchase), Expected profit (since 0.3.152: Avg value
       (EV) and "Profit: low - avg - high", 116g), Materials got,
       Disenchant value (DV), DV/EV %, Profit so far (DV - Paid), Not posted yet (units per material), Value now
       (those units at `ns.UnitValue`). Before the disenchant, Materials got says "not disenchanted yet" in grey
       and the other cells after it "-" (not known). Status headings "Not disenchanted" (first) and
       "Disenchanted, not posted" (newest first) with their count and totals, open and close
       (`ns.GroupState("ledger.batch")`); the last row is the batch's totals (bold, a line above): pieces and how
       many disenchanted, Paid, EV, Expected profit of all; DV, DV/EV % and Profit so far of the disenchanted part
       against its own EV; the units not posted and their value now. Empty: "No batch: every purchase you made is
       picked up and disenchanted, and its materials are posted." (0.3.153) No new action: the totals' help says to post from the
       Materials window.
    - d. Every window with tables is as wide as its shown columns need, up to the screen width
       (`Widgets.FitTables`, `Widgets.ScreenWidth`): `list.fitWidth` is the narrowest width that leaves no column
       out (the first column with room for its text up to 90 px; a longer first text ends with "..."). Reports
       (at least 890; 1050 since 0.3.145, 111), Gear Details (at least 620), Market (its list at least 370, the window 900 plus what the list
       grew), Materials (as wide as its columns, 84) and the Ledger (91) widen to it. `f.FitWidth` of
       `Widgets.Window`: a window sized only up and down gets exactly the width; a window sized both ways gets it
       as its smallest width (bounds first) and widens when narrower; a fixed one gets the width, and fits again
       after a size change from elsewhere (`onResize`). Measured with the fit spec's long data, 0.3.135 left out:
       Reports Bands Profit, Return, Profit each; Reports Materials Value; the Materials window Sell price ratio and
       Time to sell; Gear Details Return; Market Essences Greater. Only where the screen is too narrow does a table
       leave columns out (from the right), and then a grey note at the right end of its titles says "2 columns
       left out", with the columns and what to do in its tooltip (UI.md Tables 2).

108. **Windows of 0.3.137** (the user, 2026-11-27).
    - a. One toggle for start and stop (UI.md Controls 15, `Widgets.PlayToggle`): the play arrow while off, the stop
       square while on, the tooltip says what the click does.
    - b. The main window's Play and Stop are one toggle, left of Buy Top: stop while a scan runs (`UI.Running`:
       Play's auto scan, paused or not, or a scan once), else play. Pause left the window
       (`Scanner.Pause` stays in the code). With the auction house closed it is off, and so are the Scan once buttons and
       the Post buttons, each with the reason in its tooltip (`Widgets.ReasonTip`, `Widgets.AH_CLOSED`).
    - c. Who opened a window (`Widgets.Window`: `owner`, set when it shows, cleared when it hides; `Widgets.Opener`):
       "main" while the main window shows, "panel" from the mini panel or while the main window is closed. The main
       window's X, Escape and the Auction house button hide the windows it opened (`UI.HideOthers`: every
       `Widgets.windows` frame but the mini panel, each in `pcall`, logged with the count); they come back with it
       (24, 78). The bug the user saw (closing it left the others open) was not reproduced in the stand-in: the
       old code hid a fixed list of names in one loop, so an error in one window's OnHide kept the rest open; the
       log line says the count now. The windows' OnShow and OnHide are hooks (`HookScript`), so the owner hooks stay.
    - d. Minimize (the title bar, left of the close button: the game's "RedButton-Condense" art where the client has
       the atlas, else a "_" button; tooltip "Minimize"): the main window hides alone (`UI.Minimize`), the other
       windows stay, and the **mini panel** shows (`MiniPanel.lua`, "Salvager", fixed size, place remembered): one
       footer row with Salvager, Ledger, Reports, Market, Log (Disenchant before Log since 0.3.146, 112; two columns
       since 0.3.148, 114g). Each opens or closes its window with owner "panel",
       at the auction house or away from it; Salvager opens the main window (at the auction house its full view,
       elsewhere what it can show: the last lists, the settings, scans off with the reason). The mini panel closes
       with its own X and when the main window shows (the main window leads again); Escape leaves it (it is a
       launcher, like the minimap button, not in `UISpecialFrames`).
    - e. The minimap button: away from the auction house a left-click opens or closes the mini panel; at the auction
       house it opens or closes the main window, as before.
    - f. Away from the auction house every window opens and every tab and subtab draws without an error (spec); what
       needs the auction house is off with the reason (UI.md Actions 3).
    - g. The Ledger's Sales footer: a toggle left of Check undercuts repeats the undercut check every
       `Listings.AUTO_INTERVAL` = 60 s (from the end of one check to the start of the next) while the auction house
       is open, so the listings keep being checked after everything is posted. A check starts only when none runs,
       no cancel is on its way, no material scan runs (SDD 71) and no purchase is on its way or aimed at
       (`Scanner.Buying`); else it waits for the next tick. A repeated check says nothing in the chat unless the
       number of undercut listings changed. Off when the auction house closes and not remembered: each visit starts
       with it off (no searches the player did not ask for at this visit). Cancel undercut stays a click.
    - h. The main window's own table (Gear and Materials tabs, not `Widgets.List`): its first column takes the spare
       width, so the buttons' column ends at the list's right edge (UI.md Tables 2; measured in the layout dump of
       0.3.136: about 450 px empty at the right at 985 px). Where the columns need more than the list has, the
       window's smallest width grows to them, up to the screen; past that the first column gives way down to 90 px,
       its text cut with "..." (the full name on hover). The fit spec checks the main window's table too.
       0.3.143 (the user: the window took the whole screen on the Materials tab): the width around the list is a
       constant (`LIST_MARGIN`, 42 px), not the window's width less the list's read live: just after a tab change the
       list's width lags its new anchors, so the old sum added the whole window to the columns' need.

109. **Who undercuts you** (0.3.138, the user, 2026-11-27; `Competition.lua` pure, glue in `Listings.lua`,
    `SalvagerDB.competition`).
    - a. What the client gives (`Gethe/wow-ui-source`, branch `forever`, `AuctionHouseDocumentation.lua`,
       `CommoditySearchResultInfo`): per price line `unitPrice`, `quantity`, `numOwnerItems`, `owners` (a table of
       strings, not nilable), `totalNumberOfOwners`, `containsOwnerItem`, `containsAccountItem`. The game's own UI
       (`Blizzard_AuctionHouseUtil.lua`) shows `owners[1] == "player"` as "You", lists the names, and says "and N more"
       when `totalNumberOfOwners` is above the names given: the list can be shorter than the owners. A name can be
       "" (or "...") until the client knows it. Not measured on Forever yet: how often names are missing, and whether
       one line of many units names every owner. Your other characters' auctions (`containsAccountItem`) come with
       their names and count as competitors (the addon cannot tell them from others).
    - b. Every material search (Check undercuts, the Post window's and Stand's search, a material scan) ends in
       `Prices.Store`, which calls `Listings.Observe`: each line of others (`quantity - numOwnerItems` > 0) under the
       price of one of your live auctions of that material is an undercut. One event per owner of the line (yours left
       out: "player" and your name; "", "..." and owners beyond the names are "Unknown seller", grouped as one
       name), with the time, material, their price each, your price each (the lowest of yours above theirs), the gap,
       their units and your units above them. Not again while the same line (price, units, owner) was in the last
       search of that material.
    - c. Ledger, Sales, third subtab "Competition": one row per name, the most seen first (Name, Times seen, Last seen,
       Materials, Typical gap and Typical gap % (medians), Lowest price seen, Profit lost to them), a heading that
       opens (closed first, `ns.GroupState("ledger.competition")`) to its newest 30 events; a totals row last. Times
       seen and Last seen are the name's all-time count (`names`), which outlives the event cap.
    - d. Bounded: the newest 5000 events and 5000 loss records; names kept with their counts; posts followed 30 days.
       Clear history (88) and `/salv reset ledger` clear it; the backup does not keep it.
    - e. Profit lost to competitors: a post (`Listings.NotePost`) is followed by auction ID with its units in chunks
       { units, first price, competitors }. A cancel (`cancelDone`: known from the read of your auctions, 77a) of an
       auction whose material's last search (30 minutes at most before) had others under its price is an undercut
       cancel: its fee (the cancel cost the game named, a cancel through Cancel undercut) and its deposit lost go to
       the names under it, and its units wait an hour for a post of the same material. That post replaces them, first
       in, first out: its deposit for those units goes to the names that caused that cancel, and its units keep the
       first price of the chain (the price before any undercut) and every competitor of the chain. Units of a
       followed post that sell (`Listings.Read`, seen sold) below their first price lose (first price − sale price) ×
       units to the chain's competitors. Each record is split evenly over its names (Unknown seller gets its share).
       Not counted: units not sold (they are "at stake"), cancels and price moves with no undercut seen, sales known
       only from mail, posts not made through Salvager. Shown red with "-" (UI.md Tables 7).
    - f. Reports, fourth tab "Competition", over the Period filter, with a Material filter (All, then each material
       seen undercut) in the place of the Gear filters: a statement (Undercuts: seen, competitors, material most
       undercut; Profit lost to competitors: cancel fees and deposits, deposits of the reposts, lower sale prices, the
       total; At stake now: undercut auctions (units × gap to the cheapest line of the last search) and reposted units
       under their first price; How you answered: undercut auctions cancelled, reposted after an undercut "n of m",
       the median time from the first undercut of the auction to its repost); a table per competitor (Name,
       Undercuts, Share, Materials, Typical gap, %, Lowest price, First seen, Last seen, Active hours (the two hours
       of the day with most undercuts), Trend (against the period before of the same length: green when fewer, "-"
       for All time), Profit lost to them), each opening to its materials; a table per material (Material,
       Undercuts, Competitors, Main competitor, Typical gap, %), each opening to its competitors. Three tables, one
       inset each (UI.md Tables 3): the statement as tall as its rows up to 45% of the room, then 60/40.
    - g. Not in the books: the statement (97) already counts the deposits and fees; this splits a part of them by
       competitor, plus the lower sale prices, which no statement line shows.

110. **Times in local or server time** (0.3.139, the user, 2026-11-27; `Util.Date` and `Util.ServerOffset` pure,
    glue in `Core.lua`: `ns.Date`, `ns.Clock`, `ns.TimesName`, `ns.TimesNote`, `ns.TimeHelp`).
    - a. Options, "Prices and window": "Times shown in" (a one-choice dropdown: Local time (your computer), Server
       time (the realm)), `settings.timeZone` = "local" (default) | "server". A change fires `SALVAGER_SETTINGS`, so
       the open windows draw again.
    - b. Every shown time goes through `ns.Date(fmt, t)`: the windows' times and day headings, the Purchases days,
       the Market's Profit days and its Time of day view, the charts' times, the Competition's Active hours, the
       statements' periods and session names, the chat lines, the backup times and the activity log (its lines
       are text, written on the clock of that moment). Saved times stay Unix time. Periods ("Last 24 hours") are
       rolling, so they do not depend on the clock. A spec (`spec/times_spec.lua`) fails on any other `date(` in
       the addon; the only one left (`Prices.SeedHistory`, which reads back, once, the log of versions before
       0.3.139) is marked "not shown".
    - c. Local time is the game's `date(fmt, t)` (the computer's rules, daylight saving included, for each `t`).
       Server time is `date("!" .. fmt, t + offset)`, with offset = the realm's clock minus UTC: read from
       `C_DateAndTime.GetCurrentCalendarTime()` (year, month, monthDay, hour, minute; in `Gethe/wow-ui-source`
       branch `forever`, `DateAndTimeDocumentation.lua`), as days since 1970 × 86400 + hour × 3600 + minute × 60
       − `time()`; where it is missing, `GetGameTime()` (hours, minutes; `SystemTimeDocumentation.lua`), the
       nearest day (within 12 hours of UTC). Rounded to the nearest 15 minutes (the clock gives no seconds; every
       time zone is whole quarter hours); more than 14 hours away from UTC is not a reading. Read at
       `PLAYER_ENTERING_WORLD` and every hour after (`C_Timer`), so the realm's daylight saving change shows within
       the hour; a change is logged ("server time: UTC+2 (was UTC+1)") and draws the windows again. One offset
       for every time: a time from before the realm's last daylight saving change shows one hour off in server
       time (the client does not give the realm's rules). Until the first reading succeeds, times are local and
       say so.
    - d. Which clock: the help on time titles (Bought, Sold, Collected, Last seen, First seen, Time, Active hours,
       Day) ends with "Times in server time (the realm's clock, UTC+1): Options, Times shown in." (or local time),
       read when the help shows (`ns.TimeHelp`; a title's help text can be a function, `Tables.lua`); a statement's
       period line ends with "times in server time"; a Purchases day heading's tooltip says "Days in server time".
    - e. Day boundaries (the Purchases days, the Market's Profit days, the log's day lines) follow the clock. The
       heading states of the Purchases days are saved per day of that clock.

111. **One material order, and a search on every filter row of Reports and Market** (0.3.145, the user, 2026-11-27).
    - a. Every list of materials is in the Materials window's order: dust, then essences, then shards, each from the
       lowest level up (the order of `Data.MATERIALS`). One rule for all: `Data.MaterialRank(id)` and
       `Data.SortMaterials(list, idOf)` (pure). It orders the Market's Materials, Time of day and Essences views
       (with no column clicked: they started by Change, the biggest rise first; a click on the Material or Essence
       title sorts by that order; a sort saved before is dropped once, `windows.market.materialOrder`), the Reports'
       Materials tab (was: by sale money), the Competition tab's per-material table and the materials under a
       competitor (were: the most undercut first), and the Ledger's Accuracy materials (were: by value). The
       Competition's "Materials" cell (the three most undercut, as text) and "Material most undercut" stay by count.
    - b. A search box (`Widgets.Search`, UI.md Controls 6) is the first control of the filter row: a text box with an
       X at its right end (shown while it holds text) that clears it; Escape clears it too; Enter leaves it. Live (each
       letter), any case (`Widgets.Matches`: color, link and icon codes left out). An empty result says
       "Nothing matches "<text>". Clear the search (the X in the box, or Escape) to see every row."
       (`Widgets.NoMatch`). The Ledger's Purchases search uses the same widget (it had no X and Escape only left it).
    - c. Reports, per view (`windows.reports.search[key]`): All gold changes (what changed the gold), Gear Bands and
       History (the gear's name: the bands add up only the matching disenchants), Materials (the material's name),
       Competition (the competitor table by name, the material table by material name; the statement on top stays
       whole; the competitor totals are those of the rows shown). The Gold statement has none: a statement reads as
       a whole. Where a view has none, the Period is first. The filter row of Gear (Search, Period, Gear, Quality,
       Bands, Salvager) needs 1030 px: the Reports' smallest width is 1050 (was 890).
    - d. Market, per view (`windows.market.search[view]`): Materials and Time of day (the material's name),
       Disenchant value (the band's name, "Uncommon Armor 26-30"), Essences (either essence's name). Profit has none:
       its rows are days, which the Time filter picks.

112. **The Disenchant panel** (0.3.146, the user, 2026-11-27, after TSM's Destroy window; `DisenchantWindow.lua`,
    `Bindings.xml`, "Salvager Disenchant"). The Current batch (107c) in a small window that disenchants it.
    - a. Facts from `Gethe/wow-ui-source`, branch `forever` (read 2026-11-27): `SecureActionButtonTemplate`
       (`Blizzard_FrameXML/SecureTemplates.xml`) has only `OnClick = SecureActionButton_OnClick`. Type "spell" calls
       `CastSpellByID(spell)` for a number (`CastSpellByName` for a name); after any action, when
       `SpellCanTargetItem()` or `SpellCanTargetItemID()`, the attributes `target-bag` and `target-slot` give the
       target: `C_Container.UseContainerItem(bag, slot)` (`target-slot` alone: `UseInventoryItem`; `target-item`:
       `SpellTargetItem`). So type "spell", spell 13262 (`Data.DISENCHANT_SPELL`, the same ID the booking of
       disenchants reads from `UNIT_SPELLCAST_SENT`), target-bag, target-slot: no macro text (no spell name, which
       is localised). The click fires on key down or up after the cvar `ActionButtonUseKeyDown`: the button
       registers "AnyUp" and "AnyDown", so a mouse click and a key both cast once. `UIPanelButtonTemplate` adds
       only OnEnter and OnLeave, so "SecureActionButtonTemplate,UIPanelButtonTemplate" keeps the red button's look
       and the secure click. `C_Container` (`ContainerDocumentation.lua`): `GetContainerNumSlots(bag)`,
       `GetContainerItemID(bag, slot)`, `GetContainerItemLink(bag, slot)`, `GetContainerItemInfo` (`isLocked`,
       `itemID`, `hyperlink`), `UseContainerItem`. Auto Loot: the cvar `autoLootDefault` (`GetCVarBool`);
       `C_AutoLoot` has only `SetUseAutoLootToggle`. Not measured on Forever yet: the cast itself (whether the
       client asks for a target in between); the user checks it in the game.
    - b. In your bags (the top table): the pieces of `Ledger.Batch`'s `waiting` that are in the bags (bags 0 to
       `NUM_BAG_SLOTS`: not the bank, not worn), each slot whose item is a purchase of the batch, at most as many
       per gear as the batch has, armor or weapons of Uncommon to Epic, not `ns.NoDisenchant`. In bag order: the
       first row (with the highlight band) is the next piece. Each piece is paired with the batch's purchases of
       that gear, the oldest first (the one `Ledger.TakePurchase` books). Columns (the Current batch's, one name
       and one help): Gear (icon, name, the item's tooltip), Item level, Paid, Avg value, "Profit: low - avg - high"
       (Expected value and Expected profit until 0.3.152, 116g).
       Gear you did not buy with Salvager is never in it, so a repeated click never aims at your own gear (a copy
       of the same item as a purchase counts as that purchase).
    - c. Results (the bottom table): `Ledger.Batch`'s `done` (disenchants of the batch whose materials are not all
       posted), the last one at the top: Gear, Paid, Materials got, Disenchant value (DV), Profit so far, DV/EV %;
       the totals last (pieces, Paid, DV, Profit so far, DV/EV %). Both tables come from the Ledger's row builders
       (`LedgerWindow.BatchWaitingRow`, `BatchDoneRow`, `BatchTotals`), so the panel and the Current batch agree.
    - d. Footer: the next piece's name ("Next: ...", cut at the count) and "N left" at the left; Disenchant (the
       main action, with the next piece's icon), then Close. Disenchant is the secure button
       `SalvagerDisenchantButton`: after each bag change (`BAG_UPDATE_DELAYED`), a booked purchase
       (`SALVAGER_LEDGER`), a cast and the loot window, it aims at the next piece (out of combat only). Off, with
       the reason in its tooltip and in the footer: while Disenchant casts (`UNIT_SPELLCAST_START` to its STOP,
       FAILED, INTERRUPTED or SUCCEEDED), while the loot window is open (`LOOT_OPENED` to `LOOT_CLOSED`), with
       nothing left (no aim at all), in combat. Before each click (`PreClick`) it checks that the slot still holds
       the piece; else it aims again. Whether the character knows Disenchant is not checked (the game says it).
    - e. Combat: the client locks a secure button and every window that holds one. At `PLAYER_REGEN_DISABLED` (just
       before the lock) the button lets go of its aim and turns off, and the panel closes; at `PLAYER_REGEN_ENABLED`
       it aims again and the panel comes back if it was open (or asked for in the fight).
    - f. Opens by itself: after a bag change or a booked purchase, when a gear has more pieces of the batch in the
       bags than last seen (`SalvagerDB.disenchantSeen`, per gear; the counts follow the bags), not in combat (then
       when the fight ends), owner "panel" (it stays when the main window closes). Closed, it stays closed until
       new pieces come. The first check waits for the first bag update after a load, so a /reload does not reopen
       it. Also: the main window's footer (Disenchant, after Market), the mini panel (before Log), `/salv
       disenchant`.
    - g. A key: `Bindings.xml`, `CLICK SalvagerDisenchantButton:LeftButton` (Key Bindings, AddOns, Salvager,
       "Disenchant next piece"; a mouse wheel notch can be bound too); each press is one cast. The button exists
       from the load (built hidden), so the key works with the panel closed. The help ("?") and the button's tooltip
       say it.
    - h. Auto Loot off: a grey one-line note at the top says the loot window will need a click (the setting is not
       changed).
    - i. Size: 640 × 440 by default, at least 520 × 320, place and size remembered; as wide as its tables need
       (`Widgets.FitTables`). The top table is as tall as its rows up to 45% of the room. A size change and the bar
       only lay the tables out again (`Panel.Layout`); the rows are built on a bag change, a cast or a booked
       purchase (`Panel.Refresh`) (115b).
    - j. Filter (0.3.150, the user): Options, "Disenchant panel": Quality (Uncommon, Rare, Epic), Gear (Armor,
       Weapons), Item level from / to (0 = no limit), in `settings.disenchantFilter`; at least one quality and one
       gear type stay ticked. The panel (and so its auto-open and its button) offers only the bought gear that
       passes (`DisenchantPanel.Passes`: the link's quality, type and item level, else the purchase's judgment);
       it still never offers gear you did not buy. The Current batch in the Ledger is not filtered.

113. **Window widths and heights per view** (0.3.147, the user, 2026-11-27: the Ledger was too wide on the Odds tab).
    - a. A window is as wide as the widest table of the view on show needs, at least its smallest width, up to the
       screen, and no wider. A view change (a tab, a subtab, another material in the Breakdown, another auction in
       Gear Details) gives the window that view's width: it shrinks back where the new view needs less, down to its
       smallest width (`Widgets.FitTables(f, base, lists, view)`, `f.FitWidth(width, view)`). Before, a window sized
       both ways only widened, and the Ledger on Odds kept the width of the view before (Odds had no list it read).
    - b. A window sized both ways (Reports, Breakdown, Disenchant): the view's width is also its widest width; the
       player can make it narrower, down to its smallest width (a table then leaves columns out with its note, 107d),
       and that width (`f.userW`) holds until the next view change. While the corner is dragged only the bounds
       change. Windows sized up and down only (Ledger, Gear Details, the Odds pop-out until 0.3.148, Stand, Limits)
       are exactly that wide. The Ledger keeps the first column at its full width (`list.neededWidth`, 91); the
       others give the first column room for its text up to 90 px (`list.fitWidth`, 107d). The room around a table
       is a constant 24 px (`list.margin`), not read live (0.3.143).
    - c. Windows with more than a table: the Market (`f.fitGrows`: the view's width is its smallest, the chart takes
       more; a width the player chose stays, one that came only from another view's list shrinks back) and the main
       window (0.3.149, the user: a fixed width, as wide as the view's table needs, at least 940 and at most the
       screen; it follows the view on show, wider or narrower; only its height can be dragged; the saved width is
       dropped).
    - d. Two or more tables in a view share the window's height, each at least `Widgets.TABLE_MIN` (66 px: the
       titles and two rows): the Ledger's Sales (Open and sold) and Accuracy, the Breakdown, the Disenchant panel, the
       Reports' Competition (per competitor and per material; the summary as tall as its rows up to 45%), Gear Details
       (the upper four as tall as their rows; where the window is too low they give way in proportion, each keeping
       TABLE_MIN or its rows, and the last keeps TABLE_MIN). A bar between two tables moves the border
       (`Widgets.SplitBar`, `Widgets.SplitHeight`; 52 generalised): the share is saved per window (`salesSplit`, one
       for Sales and Accuracy, `split` for Breakdown and Disenchant, `compSplit` for Competition), 0.1 to 0.9, a
       right-click resets it. The Disenchant panel's top table stays as tall as its rows (up to 45%) until the bar
       is moved. Smallest heights: Ledger 330 (was 260: the Sales tables overlapped), Reports 352 (was 300).
       Smallest widths since 0.3.151 (115a): the Ledger 890 (was 860), the main window at least its footer.
    - e. Checked by the fit spec: no two tables of a window overlap and each is at least its titles and two rows
       high (one row where it has one); at the default size no window is wider than its view needs, and each view
       comes back at its own width after the other tabs (every tab twice); at the smallest size every view is
       checked at the smallest width (the spec sizes it down again after each tab, as the player would); the main
       window, the Ledger, the Reports and the Market shrink back after a wider tab. The stand-in found a bug of
       its own: `Widgets.CardList` kept its column flags in `stack.shown`, the field the stand-in's `IsShown` reads,
       so a hidden stack counted as shown (renamed `colShown`).

114. **The Odds in the Reports, redesigned; the mini panel in two columns** (0.3.148, the user, 2026-11-27;
    `OddsWindow.lua`, new).
    - a. The Odds view is a tab of the Reports, the last one (Gold, Gear, Materials, Competition, Odds): it is a report
       of your disenchants against the game's table, like the others, and the last place keeps the tabs the player
       uses most where they were. It left the Ledger (tabs Sales, Purchases, Accuracy; a saved view "odds" opens on
       Sales). The button at the right end of its filter row pops it out into "Salvager Odds" (`SalvagerOddsFrame`,
       place, size and open remembered, `windows.odds`); there the same button puts it back and shows the Reports on
       the Odds tab, and so does the Reports' Odds tab while it is out. While it is out the Reports show the Gold view
       in its place (not remembered). The mini panel's Reports button opens the Reports on the tab seen last (the
       Odds too). `/salv reports`.
    - b. No search and no Period on the Odds tab: the rates rest on every disenchant, all time (the tab's tooltip says
       so). Its filter rows: Gear, Quality, Bands, Salvager, the pop-out button at the right; under them (the row of
       1065 px did not fit the Reports' 1050) "Only bands with my data" and "Show with and without the Salvager". The
       filters are kept with the Odds window (`windows.odds.filter`; from `windows.ledger.oddsFilter` and the older
       keys once).
    - c. A heading per gear type (Armor, Weapons), a heading per quality under it (Uncommon, Rare, Epic), both open
       and close, remembered (`filter.collapsed`, keys as `ns.GroupedRows`); the bands have no toggle of their own
       any more. Under each quality one card per band, titled with the item level range only ("26-30"), two per
       row where both fit (each half the row), else one (`Widgets.CardList`: `pair`, `perRow`, `fitWidth` = two per
       row, `leastWidth` = one; a window that fits it gets two per row by default and can be made narrower down to
       one per row, 113). The Reports: 1266 px on Odds with the fit spec's long data (1798 with the Salvager columns);
       the pop-out the same, at least 760 (928 with the Salvager columns: one card).
    - d. Columns: the game's table, Material, Result rate, Quantity; a vertical line (`sep`); yours, Results (how many
       of your disenchants gave it), Result rate (Results ÷ Disenchants), Result quantity (the average units when it
       came; "Avg quantity" since 0.3.152, 116g). The two "Result rate" titles have keys of their own for the column chooser ("Result rate (table)",
       "Result rate (yours)"). Every title has help. Rate used, Quantity used and Price now left the columns.
    - e. The card's facts line: Disenchants and Loss chance (at the buy limit), each with its own help on hover
       (`facts` as parts). A "?" at the card's top right shows the rest on hover: Value now, Buy below, Your average
       (your average value per disenchant, all of the band's disenchants), Rates used from (99), and Price now per
       material (a tooltip, not the help panel: the cards scroll in a clipped frame).
    - f. "Show with and without the Salvager" (`filter.both`): the observed columns show the disenchants without the
       Salvager, and two columns follow, Rate with Salvager and Quantity with Salvager ("Avg quantity with Salvager"
       since 0.3.152), for the materials the
       Salvager adds to (the table's dust and essence, `bonus`; empty for shards and for what the table does not
       have). Observed only: the game has no table of it. Disenchants then says "n without, m with the Salvager".
       The Salvager filter is off meanwhile, with the reason (UI.md Actions 3); off, the observed columns follow it
       as before. Its own column set (`odds.salvager`).
    - g. The mini panel: two columns of buttons in three rows, Salvager, Ledger, Materials at the left, Reports,
       Market, Log at the right, and "Disenchant" across both under them (92 px each, the panel 216 × 162). Materials
       opens or closes the materials list in its window (20). The minimap button opens the panel away from the
       auction house, as before (108e).
    - h. Specs: the Odds rows and cards (the columns, the facts and their help, the "?", the headings, with and without
       the Salvager on a band with both, the filters, the old settings), the pop-out from the Reports and back, the
       Ledger's tabs, the Reports' tabs, the fit spec: two cards per row at the default width and one at the smallest
       (the Reports' tab and the pop-out, with and without the Salvager columns), the mini panel's columns and rows,
       its Reports button on the Odds tab.

115. **No cut text, smooth resizing** (0.3.151, the user, 2026-11-27: "check no panel is truncating text"; "the
    Disenchant panel behaves weird when resizing"; the Odds the same; the gold in the main window's footer cut).
    - a. The pass: every window, tab and subtab at the default and the smallest size, in the fit spec (106) and in
       wow-ui-sim with the game's fonts and art (`.agents/tools/wow-ui-sim/render.sh`, `SIM_ALL=1`: a cut scan per
       view; dev tool, not in git). Found and fixed: (1) an empty table's note sat in the first column and was cut
       ("No undercut in this period. Check undercuts, the Post win", Reports Competition; both Disenchant tables):
       a row with `span = true` (the note helpers of Ledger, Reports, Disenchant, Breakdown, Market, Post) spans the
       whole row, sets no column's width, and may not be cut (the fit spec checks it); the Disenchant notes are
       shorter. (2) Dropdown values cut in the game's 12 pt font (the stand-in drew the fallback's 10 pt): Quality
       "Uncommon, Rare" (Ledger, Odds, Reports: 140, was 120; the main window's "Uncommon, Rare, Epic": 180, was 160),
       Bands with three names (120, was 110, and "n bands" from three names, was four), the Reports' Material
       (200, was 150; the Period 140, was 170, its widest value 124 px), the Ledger's Show (150, was 130), the Options'
       Disenchant Gear (140, was 130). The Ledger's smallest width is 890 (was 860) for its Purchases filter row.
       (3) The main window at 940 with no data: the gold readout overlapped Log: its least width covers the footer
       (`footerBar.used` + 34, `UI.leastWidth`). (4) The Disenchant footer's reason was cut at the count: it shows a
       short one ("Nothing left to disenchant"), the full one is in the button's tooltip. (5) The gold readout
       (the user): sized from the small font's meter, which the client's coin icons outgrew, it was cut, in a fixed
       box far from the bag space. It sits right next to the bag space (8 px: gold, bags, Play), both boxes as wide
       as the text they show, measured by their own font strings (icons at their real size) each refresh; the
       footer keeps room for their widest values. (6) The Odds cards: a column after a line lost the line's 12 px, so
       it overlapped the column before by 4 px. Allowed and left: the Log's first column ends with "..." at the
       smallest width (its line in full on hover).
    - b. Resizing (the Disenchant panel, the Odds in the Reports and popped out). Causes found in the code (not seen
       in the client): each size event and each step of the bar built every row again (the Disenchant panel read
       the bags and the whole batch, `Ledger.Batch`, twice; the Odds every card from every disenchant), so the
       corner and the bar lagged the pointer; the bar's border jumped by the pointer's place in the bar at the grab;
       the cards chose one or two per row from the stack's own width, which lags the window's for a frame while it
       is sized, and a window at exactly the width two need could be a fraction short at the game's UI scale. Now:
       a size change only lays out (`Panel.Layout`, `Reports.Resized`, the pop-out's own), the bar moves the border
       from where it was grabbed and only when the pointer moves, the cards read the window's width
       (`stack.widthOf`, constant 12 px margins) with 1 px of slack. No hysteresis: with the width read from the
       window nothing feeds back into the choice. Specs: the panel and both Odds windows are dragged step by step
       both ways (each step the size asked for, bounds unchanged, the tables share the height, monotonic, no
       overlap, no rows built during the drag, one or two cards per row exactly where two fit, two switches), and
       the bar's grab moves nothing.
    - c. The Odds' Salvager columns (the user): with "Show with and without the Salvager" on, Rate with Salvager and
       Quantity with Salvager have a line before them, like Results, and their titles and values are in the
       Salvager's color, `ns.SALVAGER_COLOR` light blue (#66e0ff, about 12:1 on the panels; not the green of a gain,
       not the Rare blue); grey ("-", none) stays grey; their help says what the color means. Their chooser keys stay
       the plain titles. The main window's "Arcane Salvager bonus included" takes the same color (was the gain green).

116. **Whole-unit outcomes, the range, labelled averages, the high-return highlight** (0.3.152, the user, 2026-11-27:
    "You're calculating averages for materials that will never be output. We never get 1.5 materials, we get round
    numbers, so giving me prices based on average is misleading." and "It's ok to show the range and an average, but
    never show average numbers without reflecting that they are averages." Changes 3, 28, 99 and UI.md Words 2).
    - a. Outcomes (`Model.Results`, pure): one disenchant gives whole units of one material. For a band (the blended
       outcomes of 99: the table, the Salvager rule, your results) every (material, quantity) with its chance
       (result chance × quantity chance) and its value = quantity × (price × sell price ratio × (1 − cut) − deposits
       lost per unit), rounded to the copper; lowest value first; a material without a price is worth 0
       (`missing`); `seen` = you got exactly that in the band. Never a fraction of a unit. The chances add up to 1.
    - b. The range (`Model.Spread`, `ns.Spread`): pessimistic = the 10th percentile outcome (the best outcome with at
       most 10% of the chance below it: in 9 of 10 disenchants you get it or more), optimistic = the 90th (the worst
       with at most 10% above it). Both are real outcomes, named with their units ("1 Nexus Crystal: 59g 66s"). Two
       outcomes half and half: low and high. The average = Σ chance × value (`Model.Value`'s net before rounding).
       A deal keeps `spread`, `low`, `high` (values); its profits are each minus the buyout.
    - c. Evidence (`Model.Evidence`): observed (at least `Model.OBSERVED` = 50 of your disenchants of the band in the
       Salvager state buying uses: the blend's K), inferred (the rule is marked `inferred` in `Data.lua` and yours are
       fewer: Epic 56+, Classic's Nexus Crystal rule, not measured on Forever), else documented (the table). Where
       the rule is inferred and you never got the optimistic outcome, it is "not proven on Forever" (`unproven`):
       a grey "?" after it in the Gear list, a grey note in the tooltip, Gear Details and the Odds' "?". The user's
       Ironfeather Leggings disenchant (Epic Armor 61, 1 Nexus Crystal, with the Salvager) is in the blend and marks
       1 Nexus Crystal seen; 2 is not.
    - d. Buy limits (`ns.LimitBasis(v, outcomes)`): the rule of 73 on the average, but for an inferred band on the
       pessimistic value when lower (no unproven upside in the limit); `ns.Limits` rows say `fromLow`, Gear Details'
       "Limit set by" adds "(low value)". A hand-set limit is capped at that value too (67d). On the saved data of
       2026-11-27: Epic Armor 61+ recommended 49g 72s (1 Nexus Crystal 59g 66s, min return 20%) where the average
       was 88g 91s.
    - e. Gear list (the user's decision): one profit column "Profit: low - avg - high" (help in full), each cell one
       text "-4g 33s - +24g 92s - +55g 33s" (`ns.RangeText`, short money `Util.MoneyShort`: gold and silver from 1g,
       else silver and copper), each part green or red by its sign. Columns: Gear, Type, Item level, Buyout, Profit
       range, Loss chance, Avg return, Buy (0.4.0, the user, 2026-11-28: Loss chance next to the range; until then
       Avg return came first); Expected value left the list (its value is in the tooltip). The column
       sorts by the average (`dealSort` "profit"), Avg return by the average return; Buy Top as before. Width: the
       widest of its titles and cells now (0.4.0, 119; was the `sample` `ns.RANGE_SAMPLE`, 4-digit gold). Hovering the cell
       (`row.rangeArea`, a click passes to the row) shows the breakdown tooltip; the rest of the row the item's.
       UI.md Tables 1 has the exception.
    - f. The deal's tooltip (`UI.AddDealLines`: row, profit cell, Buy Top, the gear above it): Item level, Buyout,
       then every outcome (chance, units + material, value, profit against the buyout, lowest first), Pessimistic
       and Optimistic with their outcome, Average value and Average profit "(over many pieces)", Avg return, Loss
       chance, Time to sell, Avg return per day, the rule's evidence and "An average is over many pieces; one
       disenchant gives one of the outcomes listed." Gear Details: "How the Expected value is built" became "What
       one disenchant gives" (Outcome, Chance, Value, Profit; the pessimistic and optimistic rows say so; the
       average the last row); the deal statement says Average value and Average profit. Its default height is 780
       (was 700) so the outcomes show.
    - g. Every average says so (UI.md Words 2): Gear list, tooltips, Gear Details, Odds (Avg quantity, Avg quantity
       with Salvager, Avg value now, the range and the rule in the "?"), Market (Avg value now), Ledger (Purchases
       and Not picked up: Avg value; Current batch: Avg value (EV), and "Profit: low - avg - high", the range kept
       with the purchase, `j.lo`, `j.hi`, else the average; Accuracy: Average value (EV), Average profit (EP)),
       Reports (the stock's gear at its average value), the Disenchant panel (Avg value), the item tooltip (Salvager
       avg disenchant value, low - high), the chat ("avg profit"). A spec scans every string of the addon for
       "Expected", "expected value/profit", "Rate used", "Quantity used", "Result quantity" without "avg" or
       "average".
    - h. High returns (the user: "show any prices that are above 50% return or profit highlighted"): a deal whose
       average return is `settings.highlightReturn` percent or more (default `ns.HIGH_RETURN` = 0.5 → 50; Options,
       "Prices and window", "Highlight returns from (%)", 0 = off; `UI.HighReturn`) gets an orange row tint and an
       orange "!" after its buyout; the "!" has its help on hover ("Unusually high return (50% or more): check the
       gear, its item level and the rule behind its value before you buy (see the outcomes)."). A group heading has
       it when any auction under it has it; Buy Top's tooltip and the row's say it too. The Options window is 706
       high (was 680).
    - i. Measured 2026-11-27 on the saved data (prices of 22:07): Ironfeather Leggings (Epic Armor 61, bought at
       63g 99s 67c): 1 Nexus Crystal 51% (59g 66s, seen), 2 Nexus Crystals 49% (119g 33s, not proven); profit
       -4g 33s - +24g 92s - +55g 33s?; it would no longer be listed (over the 49g 72s limit). Azure Silk Hood
       (Uncommon Armor 26-30, 539 of your disenchants with the Salvager: observed) at 11s 99c: -7s 17c - +3s 69c -
       +35s 49c (1 Soul Dust 4s 82c; average 15s 68c; 1 Large Glimmering Shard 47s 48c).

117. **The Current batch shows the purchases in the mail** (0.3.153, the user, 2026-11-27). `Ledger.Batch` returns
    them too (`mail`: the purchases made with Buy whose "Auction won" mail is not taken, newest first; the same
    entries as Not picked up), as their own group: status headings "In the mail" first, then "Not disenchanted",
    then "Disenchanted, not posted", each with its count and totals (pieces, Paid, Avg value (EV), the average profit;
    sums of averages, said in the heading's help). Their rows are built as the "Not disenchanted" rows
    (`LedgerWindow.BatchMailRow`: Gear, Item level, Paid, Avg value, Profit: low - avg - high from the purchase's
    `j.lo`, `j.hi`, 116), the Materials got cell "in the mail" in grey. "Current batch (n)" counts them, as its help
    says. The batch's totals row includes them: "Batch: N pieces: N in the mail, N waiting, N disenchanted". The
    Disenchant panel does not list them (they are not in the bags, 112b), and Not picked up stays as it is (90). Specs:
    a purchase in the mail shows under "In the mail", moves to "Not disenchanted" when picked up, the totals add up.

118. **The self-adjusting model** (0.4.0, the user, brief of 2026-11-27, approved). The forecast learns from all
    of your results and follows a change in the game within weeks. Pure: `Model.Decay`, `Model.PriorShape`,
    `Model.ShapeAt`, `Model.LearnedShape`, `Model.ShapeDist`, `Model.Blended` (`shapeOf`); `Ledger.Results` and
    `Ledger.Shapes` (weighted); glue `ns.SalvagerShape`, `ns.KindShape`, `ns.Outcomes` in `Core.lua`.
    - a. Recency: every observation weighs w = 0.5^(d / 30), d its age in whole days (`Model.HALF_LIFE_DAYS` = 30):
       today 1, a month 0.5, two months 0.25. In every learned number: band rates and quantities (99), the Salvager
       shape (b), the sell price ratio (3), time to sell (100) and deposits lost (96), which had a 30-day window
       before; the window is gone so all of them follow the same rule (a sale older than 30 days now counts at
       half or less, never at 0). Nothing is deleted. `n` of each is the weight ("weighted results", "weight"),
       `count` the records; the floors (`Model.FEW_RESULTS` 50, `Model.OBSERVED` 50, `Ledger.FORECAST_MIN_SALES` 5)
       compare the weight. Whole days, so today's results weigh exactly 1.
    - b. The Salvager shape, one rule for all bands: a table result with m values lo..hi can come at m + 1 positions
       with the Salvager (lo..hi and one more at the top; more than one more counts as one more). Per material kind
       (dust, essence, shard, crystal; `Data.MATERIALS` kind) your weighted results with the Salvager at their
       position are pooled over every band (`Ledger.Shapes`, `cells[m][position]`). A band of another width reads
       them stretched: a result at position j of width m0 covers [j, j + 1] ÷ (m0 + 1) of the stretch lo..hi + 1
       evenly, position k at width m takes its overlap with [k, k + 1] ÷ (m + 1) (`Model.ShapeAt`). The prior is the
       community rule (2) at that width, each value 1/m, one more with `salvagerChance` (dust and essence; 0 for
       shards and crystals: never on them), with K = `Model.SHAPE_PRIOR` = 50 results: shape = (K × rule + W ×
       yours) ÷ (K + W), W the weight of yours. No results: exactly the rule (a spec: the blend equals 0.3's).
       The pool includes the band's own results; their part in the band's prior is at most K × the table's chance.
    - c. The band's blend (99) uses that shape as the table's quantities for the Salvager case (`shapeOf`): weight of
       (material, quantity) = 50 × the table's chance of the material × the shape's chance of that quantity, plus
       the band's own weighted results. So a band with 5 results starts from the shape learned in all bands (a spec:
       Strange Dust 1-2 with 5 of its own takes the thirds learned on Soul and Vision Dust). Without the Salvager:
       the table as before (min..max equally likely). The whole-unit outcomes, the range, Loss chance and the
       averages (116) read the blend, so they use the learned shape.
    - d. Options: `salvagerChance` stays, as the prior's chance ("Starting chance of one extra dust or essence
       (%)", 50), its help says that your results take over. Decision: kept rather than removed, so the prior can
       be set where the community data changes; the shape itself is learned.
    - e. Confidence (UI.md Data 2): the Odds cards have a fact "Weighted" (the weight the band's rates rest on, in
       the Salvager state buying uses, grey "few results" under 50, with its help); a card's "?" has "Rates used
       from: N weighted results (M disenchants ...)", the two learning lines (`ns.LEARNING_LINES`) and per dust or
       essence the Salvager shape it starts from ("Salvager shape, Soul Dust: 1: 35%, 2: 32%, 3: 33% (its kind in
       all bands: 451.5 weighted results ...)"). The deal tooltip says "Rests on N weighted results of this band",
       Gear Details' line the same; the material tooltip "N sales (weight x)".
    - f. Measured on the saved data of 2026-11-27 (713 disenchants, 2026-11-25 to 27, so weights 0.95 to 1; prices
       and sell price ratios of the save, no deposits): learned shapes with the Salvager at width 2: dust 34.8 /
       32.1 / 33.1% (W 451.5; yours alone 35.9 / 30.1 / 34.0%), essence 34.8 / 41.3 / 23.9% (W 114.3), shards 100%
       at 1 (W 30.7), crystal 51 / 49 / 0% (1 result). Average value old → new with the Salvager: Uncommon Armor
       1-15 (33) 2.56 → 2.53s; 21-25 (2) 7.07 → 6.97s; 26-30 (539) 15.68 → 15.64s; 31-35 (9) 17.77 → 17.57s,
       its range 2 Soul Dust 9.65s - 5 Soul Dust 24.12s → 1 Small Glowing Shard 9.47s - 6 Soul Dust 28.94s (Soul
       Dust 2-5 reads the thirds stretched: about a fifth on each of 2..6); 36-40 (15) 20.13 → 19.70s; 46-50 (2)
       83.06 → 80.16s; Epic Armor 61+ (1) 88.91 → 88.34g. Without the Salvager every band moves under 0.1%.
       Every other range is unchanged.

119. **Refreshes measured, the slow ones fixed** (0.4.0, the user's brief of 2026-11-27). Timed with `os.clock` in
    the stand-in (`spec/wow.lua`, the whole addon through its events) on the user's saved data (713 disenchants, 177
    sale records, 755 gold changes, 5000 log lines) and on a copy grown to the code's caps (5000 disenchants,
    purchases and sale records, `Ledger.MAX_RECORDS`; 20 000 gold changes, `Journal.MAX`). Targets: a refresh the
    player triggers under 50 ms (saved data) and 150 ms (caps); per tick under 1 ms; one listing of a gear scan
    under 20 µs. Before, on the caps: a settings change with every window open 441 ms, the Disenchant panel 217 ms,
    the Current batch 132 ms, Accuracy 133 ms, All purchases 127 ms; on the saved data the settings change 129-184
    ms. Causes and fixes (the results are the same, checked against the old code on the saved data):
    - a. `Ledger.Batch` walked each material's disenchants from the first for every post and sale (quadratic): the
       used-up ones are always first (first in, first out), so each material keeps its next one; a sale's post is
       looked up among that material's posts only (`postsByItem`, also in `Ledger.TimesToSell`).
    - b. A settings change checked each deal of the Gear list against `ns.Limits()` made anew per deal; one table
       for all of them now. The Options' saved data size (`Util.SavedSize` of the whole saved data, 88) is measured
       when the options show, not on every settings change.
    - c. The Ledger's summary line built and sorted `Ledger.History` (every record, with the cost shares) on every
       refresh; it reads `Ledger.HistoryTotals`. The Accuracy filter is read once per table, not per record.
    - d. Made once and kept: `ns.LevelBands` (a fixed table), `Ledger.BandKey` texts, `Model.Decay` per whole day,
       each band's table in `Ledger.Shapes`, the money texts of `Util.FormatMoney` (at most 4096, then emptied).
       The Disenchant panel reads the bags and the batch once per refresh (it read them twice, 115b).
    - e. The forecast cache (`forecastData` in `Core.lua`: sell price ratios, deposits, times to sell, results,
       shapes and each band's blend) is kept until `SALVAGER_LEDGER`, `SALVAGER_PRICES_DONE` or `SALVAGER_SETTINGS`
       (a spec: the same table until the event, a new one after it, none on other events).
    - f. After, on the caps: every refresh under 55 ms (All purchases, the slowest), one ledger, price or settings
       change with every window open about 70-115 ms, the forecast's first build 26-30 ms, a tick 0.004 ms (the
       Ledger's Sales view draws again once a second for its countdowns: 2.4 ms), a listing of a gear scan 0.7 µs,
       the load 20 ms; on the saved data every refresh under 7 ms, a change with every window open about 15 ms.
       The layout dump at logout with every window open: about 210 KB (bound 600 KB, 94) in about 22 ms. Left: the
       Market's Profit chart draws one segment per sale (5000 at the caps: 91-152 ms in the stand-in, most of it the
       stand-in's own anchor check, about 11 ms the addon's); not changed, as it is drawing code.

## Files

The TOC's order: pure modules first (no game API, the specs load them alone: `Util`, `Data`, `NoDisenchant`,
`Model`, `Ledger`, `History`, `Journal`, `Statement`, `Competition`), then `Core` (namespace, saved data, events,
the forecast glue, slash commands), the game glue (`Queue` searches, `Items` item levels, `Prices`, `Scanner` the
gear scan and buying, `Disenchant`, `Mail`, `Gold` the journal's glue, `Report` the chat report, `Backup`,
`Tooltip`, `Listings` your auctions, `Convert` essences), the widgets (`Widgets`, `Tables`, `Chart`), and the
windows (`Post`, `MaterialsWindow`, `LimitsWindow`, `UI` the main window, `LedgerWindow`, `StandWindow`,
`BreakdownWindow`, `GearWindow` Gear Details, `MarketWindow`, `OddsWindow`, `ReportsWindow`, `DisenchantWindow`,
`LogWindow`, `Options`, `MiniPanel`, `Minimap`, `Layout` the layout dump, 94). `Bindings.xml`: the Disenchant key (112g).

## Data

`SalvagerBackup` (account-wide): `list` of ledger copies (88). `SalvagerDB` (account-wide): `settings` (`timeZone`, 110, `highlightReturn`, 116h), `prices`, `ledger` (`purchases`, `stock`, `pools`, `disenchants`, `sales`),
`money` (gold journal), `sessions` (97), `competition` (109), `disenchantSeen` (112), `quality` and `ilvl` (learned item data), `auraSeen` and `auraSnapshots` (to learn the Salvager's aura spell ID; matched by name until then),
`posted` and `listings` (29), `history` (57), `log` and `logDay` (69), `windows` and `window` (places, sizes, views and
filters), `groups` (103), `columns` (95), `layout` (94), and one-time flags (`historySeeded`, `buyResendBlocked`, 65,
`falseCancelsDropped`, 75, `firstSalvagerBatchFixed`, 74b).

## Open

1. Whether Boosted Disenchanting (1283701) stacks with the time spent near the Salvager, and whether the
   bonus grows with it: read `salvagerStacks` and the results after the next batches (74b).
2. Whether Forever's disenchant results match the Classic table in the bands with few results: the Reports' Odds
   compare them per band (114). Epic 56+ rests on Classic's rule (inferred, 116c): one Epic Armor 61 disenchant so far
   (1 Nexus Crystal, with the Salvager); 2 Nexus Crystals not proven.
3. Whether a band of four values (Soul Dust 2-5) gets the stretched Salvager shape (118b; 9 results so far) or one more
   half of the time: check with about 50 disenchants with the Salvager in 31-35 or 41-45.

Answered: essences get the Salvager bonus, about half the dust's (74a, 0.3.125), and the shape is learned per material
kind from all bands (118).

120. **One width authority; windows and columns as tight as their content** (0.4.0, the user, 2026-11-28: "Why is
    controlling the size of columns so damn hard, I've told you many times to keep windows tight and it keeps getting
    bigger. Are you even testing?"; "set up guardrails in code and don't rely on prose"). Measured in his layout dump of
    0.3.151: the empty Current batch spread its 11 titles over 940 px (gaps of 53 to 80 px), the Materials window was
    1092 px with 170 px of spare in its first column, the main window's empty Gear list 986 px. The causes found in the
    code: every window held a raised constant as its smallest width (Reports 1050, Ledger 890, main 940, Odds 760,
    Breakdown 720, Gear Details 620, Disenchant 520, Market 900 with its list at 370, Materials 520), sized for the fit
    spec's extreme data or its longest filter row with every filter shown; the gold readout kept room for the gold cap;
    the range column a 4-digit-gold sample; every column 10 px of padding and 6 px gaps, so texts sat 6 to 26 px apart
    by their justification; the first column took whatever the window had over that; and no spec tested that a window
    is no wider than its content needs.
    - a. The width authority (`Widgets.lua`, "the width authority"): a column is `ceil(widest text now) + CELL_PAD`
       (2) — its title with its sort arrow, the rows of the data (up to 400), a total in its larger font, a control's
       width where the column holds one (`least`: the Limits' money boxes); `sample` only for a live column (the
       countdowns, the Age) and only while it has rows. Two columns' boxes are `Widgets.ColumnGap(a, b)` apart so their
       texts are NORMAL_GAP (16 px) apart whatever their justification. `Widgets.FitColumns` (every table: List,
       CardList, the main window's own) and `Widgets.FitTables(f, lists, view, extra)` (every window with a table) are
       the only places that size them. A window is as wide as its widest row of content now: a table's columns with the
       first one in full (`list.neededWidth`), an empty table's note (never cut, UI.md Tables 6), a row of controls
       (`bar:Need()`: the regions on show, measured where they are drawn, `bar.parts` with their side), the title, and
       `f.extraNeed` (the main window's settings block, the Breakdown's and Gear Details' headings, the Competition
       titles, the Post's market lines, the Stand's facts). No window keeps a constant smallest width: the smallest is
       its controls' (and notes', and one card per row). The first column takes only what the window has over its
       columns (a few px, or what the controls force). The gold and bag readouts are their text now.
    - b. Cells: money of 1 gold or more shows gold and silver (`Util.ShortMoneyText` through `Widgets.CellText`, in
       every table cell, measured and drawn alike), the full amount on the row's hover (`Widgets.AddExactLines`).
       "(few sales)" became a grey value with "*", explained in the column's help and the row's hover
       (`ns.FEW_SALES_NOTE`, `row.notes`).
    - c. The self-check (`Widgets.CheckLayout`, always on, after each fit): the window no wider than its content's
       need + 8 px (`SLACK`), every column gap within NORMAL_GAP + 4 (the first one may be what the controls give it).
       One Log line per window and view per session: "layout: <window>/<view> wider than its content by N px", or
       "column gaps over 16 px: <title>><title> <px>". `make layout` lists them with the dump.
    - d. The gates: (1) `spec/tight_spec.lua` with typical data (the shapes of the user's own: its material prices,
       its most bought gear, a few gold): every window, view and size, measured from the stand-in's rects
       (`spec/layoutcheck.lua`: tables, rows of controls, the settings, headings, notes): no window wider than its
       tightest row + 8 px, every gap 16 ± 2 px, nothing cut; the same with no data; a window shrinks when its table
       empties; no width change over 10 refreshes or a round of the tabs; the countdowns draw only their cells. On the
       code before this change it found 113 too-wide views and 96 gaps. The extreme-data checks of `fit_spec` stay
       (nothing cut, at most the screen). (2) The real-font gate, `make sim-check` (`.agents/tools/wow-ui-sim/check.sh`,
       a local dev tool, not in git; skipped with a message where it is missing): every window and view with the
       game's fonts, the same rules, a table, exit 1 on a problem; on the old code 63 of 64 views were too wide (the
       Reports' Gold by 646 px). `make install` runs `check` and `sim-check`. (3) `make layout` adds the same rules on
       the client's dump and the self-check's Log lines.
    - e. The Ledger's countdowns draw only their cells each second (`list:RefreshLive`, `row.live`): the whole table
       each second took 2.4 ms at ten times the data. Options' "and reopen the windows that were open last time" (all
       come back since 0.3.137). The Market drops a width saved before this change once (`saved.tightW`).

121. **Ratchets** (0.4.0, the user, 2026-11-28: "Have ratchets so we don't fuck up things again"). Numbers that may only
    get better, in git: `spec/ratchet.json`. The specs write what they measure to `.ratchet/` (gitignored):
    `layout-typical` and `layout-empty` (tight_spec: per window, view and size the width, the largest gap, cut texts,
    overlaps), `layout-extreme` (fit_spec: cut texts, the width up to the screen), `perf` (`spec/perf_spec.lua`:
    synthetic data at the caps, 5000 purchases, disenchants and sales; each window and view's refresh, best of 3, the
    countdown tick, the scan's judge per listing) and `suite` (the specs passed, luacheck's warnings).
    `scripts/ratchet.lua` (Lua 5.1, run in the test image) compares: a width larger by more than 1 px, a larger gap, a
    cut text or an overlap, fewer specs, a luacheck warning, a timing over 1.5 times its baseline (2 ms floor) is
    worse; `make check` fails with a table of what got worse and by how much. `make ratchet` moves the baseline to the
    better numbers only (a timing only when 20 % better, so a lucky run does not set it) and adds new ones; a looser one
    needs `make ratchet ALLOW_WORSE=<Lua patterns on set:key:field> REASON="why"`, and the reason goes into the file's
    `reasons`. `spec/ratchet_spec.lua` proves it: a column made 40 px wider fails the check, the baseline does not move
    to it without ALLOW_WORSE. The sim gate keeps its own baseline beside the tool (`ratchet.json` there, local).

