# Download metadata

New tasks keep optional `DownloadMetadata` alongside the existing record. Existing
records decode without it. Missing metadata is shown as unavailable; historical
completion dates are not guessed. `updateDates` is reserved for explicit task
source/link updates, not progress, pause or retry operations. Completion time is
recorded when a task first transitions into `finished`.

Plugin `parse` results may include `videoID` and `duration` at the result level.
Each variant may supply `videoID`, `width`, `height`, `duration`, `videoCodec`,
`audioCodec`, `frameRate`, `bitrate`, `audioLanguage`, and `subtitleLanguage`.
Variant values take precedence. No video identity hash is computed.

A plugin manifest may supply `sourceNormalization`, an array of explicit rules:

```json
{
  "identifier": "example-language-path-v1",
  "host": "example.com",
  "pattern": "^(https://example\\.com)/(?:en|zh|ja)/video/",
  "replacement": "$1/video/"
}
```

Rules apply only to that exact host, first match wins, and the result must retain
the host. Without a matching rule, the final page URL is retained unchanged and
no rule identifier is saved. No universal language-removal regex is applied.
The original page URL and final page URL are preserved separately.
