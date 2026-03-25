How to test it:

Extract RawAHExport into your WoW Interface/AddOns/ folder.
Launch the game and enable the addon.
Open the Auction House.
Run /rahexport scan
After the scan completes, /reload or log out so SavedVariables are written.
Check WTF/Account/<ACCOUNT>/SavedVariables/RawAHExport.lua

Included commands:

/rahexport scan
/rahexport status
/rahexport tracked
/rahexport reset

Current behavior:

full AH replicate scan
TRACKED_ITEMS table defined in code
full itemSummary per scanned item
filteredRows saved only for tracked itemIDs
topUntracked stores the top 100 untracked items by quantity/auction count

One thing to watch in testing: if your Anniversary client uses a different TOC interface number than 11507, the addon may show as out of date until you change that number.
