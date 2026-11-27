# UI and UX rules

These hold for every window of the addon. A change that breaks one of them is a bug.
The agent cannot see the game: a layout change is unverified until the user confirms it, and the
reply must say so.

## Actions

1. An action the player clicks happens. It is never refused with "wait" or "try again".
   If it cannot run now, it runs as soon as it can, by itself, ahead of background work.
2. Buying comes before everything: a Buy click stops scans and searches at once, until its purchase is answered.
   Where the mouse is never stops a scan. When the game cannot take the purchase in that click (the auction house
   is busy, or a browse made its search stale), nothing is sent into the void: a row's Buy says "Buy now", lit, with
   a chat line, the moment it can, and that click buys. Never a silent wait. Buy Top, made for fast clicks, says
   "..." with the reason while the auction house is busy and is back the moment it is ready.
3. A control that cannot do anything is disabled, with the reason in its tooltip. It does not
   print an error when clicked.
4. Background work (scans, refreshes) never removes, moves or empties what the player is looking
   at. A list is emptied only by a click that asks for new content.
5. Cancel is the last button of its group. The main action comes before it.
6. Destructive actions ask first, and say what stays.

## Controls

1. A window from top to bottom: title bar and close button (top right); main tabs; the view's subtabs; the view's
   filter row; the content; the footer (totals, status, the window's actions). A view's summary line is with its
   content, under the tabs, never above them.
2. Each kind of control has one look, from one widget, and no other kind uses it: tab (`Widgets.Tab`), subtab
   (`Widgets.Subtab`), dropdown with its arrow (`Widgets.Dropdown`), check box (`Widgets.Check`), action button (the
   red button, `Widgets.Button`). A tab or a dropdown is never a red button. Rows are made with `Widgets.Bar`.
3. A row of tabs or subtabs holds tabs only: no filter, no action, no readout.
4. A filter is in the filter row directly above the content it filters. Never next to a tab.
5. A filter has a label at its left that says what it filters ("Period:"), and shows its value in full (a dropdown is as wide as its widest value). "All" is the first
   option. A filter that hides rows shows it and clears in one click. A check box has its label at its right.
6. Filter row order: search, filters, then the table's actions at the right end.
   A search is one widget (`Widgets.Search`): a text box with an X at its right end that clears it in one click,
   Escape clears it too; it narrows the rows live, in any case, by the view's first column (its names); each view
   keeps its own text; a search that finds nothing says "Nothing matches <text>". A statement has no search.
7. Status (bag space, gold, progress) is in the footer. The window's main action is at the bottom right. A
   destructive action stands apart from the frequent ones and is never the default.
8. Tabs separate different content. A choice that only narrows or re-sorts the same content is a filter.
9. The selected tab shows it in two ways (shape and text color). Tab titles are nouns, one or two words; six at most.
10. What belongs together is close and aligned; what does not is apart by a clearly larger gap; a group of settings
    sits in its own inset with a heading (the main window's Scan settings), apart from the tabs and the list.
11. Text that cannot be clicked never looks like a control.
12. Text contrast 4.5:1 or more; control edges 3:1; one color means one thing everywhere.
13. Buttons that open other windows are one group in the footer, at its left (the main window: Auction house, Ledger,
    Reports, Market, Disenchant, Limits, Log, Options), never where they read as tabs. The mini panel is only such
    buttons: two columns (Salvager, Ledger, Materials; Reports, Market, Log), Disenchant across both under them.
14. Checked by the specs (rows of tabs hold tabs only; filters under the subtabs; every row fits the smallest width;
    `spec/fit_spec.lua`: no cut text, no overlap in a row, nothing outside its window, at the smallest and the
    default size, SDD 105)
    and by `make layout` (a row of tabs with another control; a statement's amounts not at the panel's right edge; a
    tab, subtab or dropdown with the red button's art).
15. Start and stop of one thing is one toggle button: the play arrow while it is off, the stop square while it runs;
    its tooltip says what the click does (the main window's scans, the Ledger's repeated undercut check).

## Tables

1. One value per cell. A number and its percentage, or a rate and a quantity, are two columns. One exception (the
   user, 2026-11-27): the Gear list's profit is one range cell, "pessimistic - average - optimistic" (title "Profit:
   low - avg - high", its help in full), each part green or red by its sign; the column sorts by the average, and
   the cell's hover lists every outcome. A range is never a single number in disguise: its parts are real outcomes
   and the average, each named.
2. A column is as wide as its widest content, title included (with its sort arrow). No fixed spare width, the button
   column included. The first column (the row's label) takes the spare width, so the last column ends at the
   table's right edge, in every table (as in a statement, Statements 2; the main window's own Gear and Materials tables
   too); in a stack of cards, the columns line up
   at the cards' right edge. Text that does not fit ends with "..." and shows in full on hover. A column of live
   values is as wide as its widest possible value (`sample`). A window is as wide as its tables' shown columns need,
   up to the screen, and no wider: a tab change gives it the new view's width (narrower too), never the width of
   the view before; a column is never left out silently: where the screen (or a window the player made narrower) is
   too narrow, a note at the right end of the titles says how many are left out, and its tooltip which ones.
3. A table with sections is one inset per section, or a heading row per section with its own
   totals. A value that is the same for every row of a section goes in the heading, not in the rows.
4. Rows the player acts on first come first (open before sold, newest before oldest).
5. A marker that belongs to a row (your price, your break-even) is on that row, not on a line
   next to it.
6. An empty table says why it is empty and what fills it, in full: the note spans the row, never cut.
7. Money has coin icons, right-aligned. An unusually high average return (Options, "Highlight returns from (%)",
   default 50) tints the Gear row orange with "!" after its buyout and its reason on hover (orange: a warning, as
   everywhere). Every signed number (gold, a profit, a forecast, a gap from a forecast,
   a percent change) is green when it is good (a gain, more than planned) and red when it is bad, with its + or -
   (the user, 2026-11-26: grey forecasts read as "nothing there"). Grey is only for what is not known, rests on
   too few samples, or is a note. Color is never the only signal: the sign or a word says it too.
8. Text, names and dates left-aligned. Numbers, money, percentages and times right-aligned. A title aligns like its
   column.
9. The numbers of a column have the same decimals and unit. Silver and copper show two digits after a larger coin,
   so the coins line up. A percentage keeps its "%".
10. One sort arrow, on the sorted column. A click on the title reverses it. The sort is remembered.
11. Rows are told apart by space and a highlight under the pointer, faint stripes in wide tables. No grid.
12. The titles stay in view when the table scrolls. Titles and rows have one height in every table.
13. A totals row is the last row, with a line above it; it does not sort.
14. A column computed from others is at their right. While a table loads it says so, not "nothing".
15. A group heading opens and closes; its arrow shows the state; the state is remembered. The arrow is at the left
    of the heading and points right while closed, down while open (`Widgets.GroupArrow`); the whole heading row is
    the click target, with the hover highlight; a closed heading keeps its totals. One implementation for every table
    with groupings: `ns.HeadingToggle`, `ns.GroupedRows` with `ns.GroupState(<table>)` (saved data).
16. Every list of materials is in one order, the Materials window's (dust, essences, shards, each from the lowest
    level up): `Data.SortMaterials`. A click on a column title may re-sort it; with none, that order.
17. A stack of small tables of the same kind (the Odds' bands) sets two next to each other where both fit, each half
    the width, else one per row; a heading row stays across the whole width. Their columns line up in every card.

## Statements

1. The heading says what it is, for which character and for which time.
2. Labels at the left; amounts in one column flush with the right edge of the panel. The label column takes the
   spare width. Faint stripes or a highlight carry the eye across.
3. A section is a heading row without an amount; its lines are indented one step; its total is at the heading's level.
4. A thin line above a total's amount, a double line under the last total. Totals are bold. No "=" lines.
5. One sign rule in the whole statement: "+" comes in, "-" goes out, on every amount. Every total is the sum of the
   lines above it since the last total.
6. Every line reads without the pointer; the hover says how it is computed.
7. A comparison with another time is a second amount column at the right, with the same rows.

## Words

1. The game's own words: Uncommon, Rare, Epic; Armor, Weapons; disenchant; buyout; auction; item level.
   Never the color names for qualities.
   Gear = what you buy and disenchant (armor, weapons): "gear", "a piece of gear", "the Gear tab". Materials = what a
   disenchant gives (dust, essence, shard). Never "item" for gear ("All gear you bought", not "Every item you
   bought"), never "mats" or "resources" for materials. "Item" stays for a game item in general (a tooltip, a link).
2. Trading terms, the same everywhere: Average value (Avg value in a tight title), Disenchant value, Sold value,
   Average profit (Avg profit), Avg return, Profit, Loss chance, Break-even, Result rate, Avg quantity (the average
   units when a result came), Pessimistic and Optimistic (the outcomes 9 in 10 and 1 in 10 disenchants reach), Sell
   price ratio (what a unit really sold for against its price when posted), Time to
   sell (from the post to the sale), Avg return per day (Avg return ÷ the days until the materials sell, at least 1). One
   thing has one name in every window.
   What a disenchant gives is a result, never a "drop".
   An average is never shown without saying it is one (the user, 2026-11-27: "never show average numbers without
   reflecting that they are averages"): its title or label says "average" or "avg", and its help says it is the
   average over many pieces while one disenchant gives one of the outcomes; a sum of averages is an average too. A
   quantity is whole units; an average of units says "Avg quantity". "Expected" is not used (a spec scans for it).
   Their abbreviations: EV (Average value), DV (Disenchant value), SV (Sold value), EP (Average profit),
   AP (Actual profit). A column that compares two values is named for them, with the abbreviations:
   "SV/DV %" (percent), "SV - DV" (coins), never "Diff" or a nickname. A value title shows its abbreviation in
   parentheses ("Sold value (SV)") where a comparison column of the same table uses it, and only there. The
   help on a comparison title says it in full and names both terms.
3. A title says what the column holds ("Price now", not "Price"). No verbs as titles ("Got",
   "Came").
4. Every title that is not obvious has help on hover. Static explanations are behind the "?"
   button, one line each; the screen keeps only live information.

## Layout

1. A setting lives in one place. What the main window sets is not in the options.
2. Windows remember their place, size, tab and filters. A window that only lists content fits it;
   a window with long lists is resizable in the direction that helps.
3. Secondary views are subtabs of the view they belong to, the main one first. Two levels at most; subtabs look
   different from tabs: each is a segment of a segmented control (a small box with an edge, so it reads as
   clickable; the selected one filled gold), smaller and flatter than a tab, never a red button.
4. Live values (countdowns, gold) update while they show.
5. The main window leads: the windows it opened close with it (X, Escape, the Auction house button) and come
   back with it. Its Minimize button hides it alone and shows the mini panel (one button per window); the windows
   opened from the mini panel, or while the main window is closed, are independent of it. The game's auction
   house is one click away (Auction house button), and Salvager one click back (its button under the
   auction house). Hiding windows never stops a scan.
6. Nothing overlaps, at the smallest size a window allows. Two or more tables in a view share the height, each at
   least its titles and two rows; a bar between two of them moves the border (drag it; a right-click resets it). A filter row that is full wraps to a second filter row,
   or the window's smallest width grows; a control never moves to a row of tabs. A text that can grow either wraps
   and pushes what is under it down, or is one line cut at the next control.
7. A window can be dragged partly off the screen, until 40 px of its title bar are left, so it can always be
   dragged back. `/salv windows reset` brings every window back on the screen.
8. Only a question about a destructive action blocks the game. Every other window leaves the game usable.
9. Every window has the close button at its top right. Escape closes the windows (`UISpecialFrames`).
10. A window's title is "Salvager <Name>", the name capitalized like a name, every word: "Salvager Ledger",
    "Salvager Gear Details". The main window is "Salvager".

## Data

1. What the player is told to pay for is checked against the thing itself (the auction's own
   item), never trusted from the context it arrived in.
2. A number that rests on few samples says so.
3. Times follow the Times option (Options, "Times shown in": local or server time, SDD 110): every shown time and day
   goes through `ns.Date`, and where the clock matters (a time column's help, a statement's period line) it says
   which one.
