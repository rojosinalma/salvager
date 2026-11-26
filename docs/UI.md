# UI and UX rules

These hold for every window of the addon. A change that breaks one of them is a bug.
The agent cannot see the game: a layout change is unverified until the user confirms it, and the
reply must say so.

## Actions

1. An action the player clicks happens. It is never refused with "wait" or "try again".
   If it cannot run now, it runs as soon as it can, by itself, ahead of background work.
2. Buying comes before everything: a Buy click stops scans and searches at once.
3. A control that cannot do anything is disabled, with the reason in its tooltip. It does not
   print an error when clicked.
4. Background work (scans, refreshes) never removes, moves or empties what the player is looking
   at. A list is emptied only by a click that asks for new content.
5. Cancel is the last button of its group. The main action comes before it.
6. Destructive actions ask first, and say what stays.

## Tables

1. One value per cell. A number and its percentage, or a rate and a quantity, are two columns.
2. A column is as wide as its widest content, title included. No fixed spare width, the button
   column included. A column of live values (a countdown) is as wide as its widest possible value
   (`sample = "00:00:00"`), so it does not shrink while it counts.
3. A table with sections is one inset per section, or a heading row per section with its own
   totals. A value that is the same for every row of a section goes in the heading, not in the rows.
4. Rows the player acts on first come first (open before sold, newest before oldest).
5. A marker that belongs to a row (your price, your break-even) is on that row, not on a line
   next to it.
6. An empty table says why it is empty and what fills it.
7. Money has coin icons, right-aligned. Gains are green, losses red. Color is never the only
   signal: the sign or a word says it too.

## Words

1. The game's own words: Uncommon, Rare, Epic; Armor, Weapons; disenchant; buyout; auction.
   Never the color names for qualities.
2. Trading terms, the same everywhere: Expected value, Disenchant value, Sold value, Expected
   profit, Profit, Loss chance, Break-even, Drop rate. One thing has one name in every window.
3. A title says what the column holds ("Price now", not "Price"). No verbs as titles ("Got",
   "Came").
4. Every title that is not obvious has help on hover. Static explanations are behind the "?"
   button, one line each; the screen keeps only live information.

## Layout

1. A setting lives in one place. What the main window sets is not in the options.
2. Windows remember their place, size, tab and filters. A window that only lists content fits it;
   a window with long lists is resizable in the direction that helps.
3. Secondary views are subtabs of the view they belong to, the main one first.
4. Live values (countdowns, gold) update while they show.
5. Nothing overlaps, at the smallest size a window allows. A control row that is full moves controls to the
   row of the view they belong to (Odds filters on its subtab row). A text that can grow either wraps and
   pushes what is under it down, or is one line cut at the next control.

## Data

1. What the player is told to pay for is checked against the thing itself (the auction's own
   item), never trusted from the context it arrived in.
2. A number that rests on few samples says so.
