# Changelog

## Salvager 0.4.1

### Buying
- Play runs a live scan: short rounds that look only at the cheapest listings of each quality, gear type and item
  level band, search only the gear that is new, cheaper or more since its last search, and make the top three deals
  current again. Between rounds the scan rests (8 seconds by default, Options), so the auction house is free when you
  click Buy, and a Buy click goes through at once. Nothing is sent for 3 seconds after a Buy click, so a buying
  streak keeps the auction house.
- The status line says what the live scan does: "Live: 18 targets, round 2.1 s, next in 6 s".
- If the auction house does not return the listings in price order, Play falls back to the full rounds (every page)
  for the rest of the session and says so. Scan once: Gear always reads every page.
- The log has one line per round and per purchase (time from click to answer), so the timing can be checked.

## Salvager 0.4.0

The biggest update since 0.3.113: a new forecast, honest books, and a new interface.

### Buying
- Profit as a range: every deal shows its pessimistic, average and optimistic profit from real, whole-unit results
  (one disenchant gives 1 or 2 crystals, never 1.5). Hover the profit to see every possible result and its chance.
- Every average is labelled as an average. Rules that were never measured on Forever (for example Epic 61+) are
  marked, and their buy limit uses the pessimistic value.
- The forecast learns from your own disenchants, per band, and learns the Arcane Salvager bonus from all of them;
  recent results count more, so a game change shows within weeks.
- Unusually high returns (50%+ by default) are highlighted as a warning.
- Purchases during a scan: a click is never lost in silence; Buy Top keeps buying one auction per click.

### Books and reports
- Material costs are shared per band, so every material's cost, break-even and profit is faithful.
- Every purchase is kept until you disenchant it: older versions kept only the last 50 purchases of one item, so
  in a big batch the rest were disenchanted at no cost and the profit looked higher than it was. At the first load
  of 0.4.0 those purchases are rebuilt once from the auction house record (after a backup, with a line in the Log),
  and the costs and profits that follow are booked again. When a list of records is full, the Log now says so.
- Your history is kept: records older than 30 days are rolled up per day instead of dropped, so the Reports, the
  Accuracy, the Odds and the forecast keep everything they learned, and the saved file stays small.
- A books check at the end of the gold statement: what you paid, plus stock from before your records, equals what
  your sales and your stock cost, to the copper. The cost sharing of 0.3.120, which could book a few silver too much
  on stock from before your records, is repaired once.
- Reports: a gold statement per session or period (trading profit, stock change, a check against your gold),
  Gear (Bands, History), Materials, Competition (who undercuts you and what it cost you) and Odds.
- Ledger: purchases grouped by day and status, Mail and Pending (from the mailbox to the last post), Accuracy with
  labelled averages.
- Times in local or server time (Options).

### Windows
- One order everywhere: tabs, subtabs, a filter row, the content, a footer; real game tabs and dropdowns.
- A mini panel, always on (Shift + click the minimap button to hide or show it), with a button for every window;
  the main window's footer keeps only the status, gold, bags, Play and Buy Top, and its options are a gear icon in
  the title bar. A Disenchant panel with a one-key disenchant button and a filter in Options.
- Two macros made for you: Salvager Buy (Buy Top) and Salvager DE (the Disenchant button), for your bars or keys.
- The Arcane Salvager bonus is a check box in the Scan settings (was Options' Auto/On/Off; your choice carries over).
- Every column sorts by a click on its title, and remembers it; grouped tables sort inside their groups.
- The Odds cards: Game rates, Your rates and Salvager rates as headed groups (Rate, then quantity), and a facts row
  with Results, Disenchants without/with the Salvager, Weighted (red when too few) and Loss chance; the headings sum
  up their bands.
- The Market window is now Charts (Profit, Materials, Bands, Time of day); the Ledger's Purchases subtabs are Mail
  and Pending.
- No cut text: long status lines wrap, every help shows one point per line, and chart labels stay inside the chart.
- Windows and columns as tight as what they show: every column as wide as its text, the same small gap between
  columns, a window no wider than its widest table or row of controls, narrower again when a table empties. Amounts
  of 1 gold or more show gold and silver in tables (the copper on hover); "few sales" is a grey value with "*".
    Every table spans its window; where a view has two tables, the narrower one's first column takes the room.
- The Gear list shows Loss chance next to the profit range, before Avg return.
- Windows resize smoothly, can be dragged partly off the screen (/salv windows reset), and remember their place.
  Search boxes in Reports and Charts.
- Faster with a long history: a settings change, the Ledger's Pending, Accuracy and purchases, and the
  Disenchant panel redraw several times faster with thousands of records.
