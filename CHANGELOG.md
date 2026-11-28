# Changelog

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
- Reports: a gold statement per session or period (trading profit, stock change, a check against your gold),
  Gear (Bands, History), Materials, Competition (who undercuts you and what it cost you) and Odds.
- Ledger: purchases grouped by day and status, a Current batch from the mailbox to the last post, Accuracy with
  labelled averages.
- Times in local or server time (Options).

### Windows
- One order everywhere: tabs, subtabs, a filter row, the content, a footer; real game tabs and dropdowns.
- A mini panel (minimap button, away from the auction house) and a Disenchant panel with a one-key disenchant
  button and a filter in Options.
- Windows and columns as tight as what they show: every column as wide as its text, the same small gap between
  columns, a window no wider than its widest table or row of controls, narrower again when a table empties. Amounts
  of 1 gold or more show gold and silver in tables (the copper on hover); "few sales" is a grey value with "*".
  Where a view has two tables, each is only as wide as its own columns.
- The Gear list shows Loss chance next to the profit range, before Avg return.
- Windows resize smoothly, can be dragged partly off the screen (/salv windows reset), and remember their place.
  Search boxes in Reports and Market.
- Faster with a long history: a settings change, the Ledger's Current batch, Accuracy and purchases, and the
  Disenchant panel redraw several times faster with thousands of records.
