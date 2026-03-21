# web-search

Pi.dev extension that gives the LLM two tools for consulting the web during coding sessions.

## Tools

### `web_search`

Searches DuckDuckGo (no API key, no account required) and returns up to 8 results with
titles, URLs, and snippets. Use when the model needs current documentation, release notes,
library APIs, or any information not in its training data.

### `web_fetch`

Fetches the full text of a URL. Strips `<script>`, `<style>`, `<nav>`, `<header>`, and
`<footer>` blocks, collapses whitespace, and truncates to 12,000 characters. Use after
`web_search` to read the complete content of a result page.

## Usage

The tools are registered automatically when the extension loads. Just ask the model to
look something up:

```
Search for the vLLM changelog for version 0.9.0
```

```
Find the Qwen3 model card on HuggingFace and summarize the recommended vLLM flags
```

## Backend

Uses DuckDuckGo's free HTML endpoint (`https://html.duckduckgo.com/html/`). No API key,
no rate-limit registration, and no personally identifying headers are sent. HTTP requests
time out after 15 seconds.

## Limitations

- DuckDuckGo HTML scraping may break if DDG changes its page structure.
- Pages that require JavaScript rendering return little or no content.
- Results are in English (`kl=us-en`).
