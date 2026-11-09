# Download metadata

New tasks keep optional `DownloadMetadata` alongside the existing record.
It stores the source page URL, parser name (without a version), optional request
headers, explicit task-update dates and completion date. Quality and format
remain on the download record itself.

Existing records decode without metadata. Unknown fields from the earlier
metadata format are ignored and disappear when the task list is saved again.
Completion dates are not inferred for historical tasks. `updateDates` is reserved
for explicit task source/link updates, not progress, pause or retry operations.
Completion time is recorded when a task transitions into `finished`.

No URL normalization, video identity hash, video ID or extended media attributes
are stored. Task details show unavailable values explicitly, omit absent update
history, and show failure reasons only for failed tasks.
