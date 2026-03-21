import * as https from "node:https";
import * as http from "node:http";
import { URL } from "node:url";
import { Type } from "@sinclair/typebox";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// Maximum number of search results to return per query.
const MAX_RESULTS = 8;

// Maximum characters to include from a fetched page.
const MAX_PAGE_CHARS = 12000;

// Timeout in milliseconds for HTTP requests.
const REQUEST_TIMEOUT_MS = 15000;

interface SearchResult {
	title: string;
	url: string;
	snippet: string;
}

/**
 * Fetch a URL and return the response body as a string.
 * Follows a single redirect. Rejects on timeout or non-2xx status.
 */
function fetchUrl(url: string, extraHeaders: Record<string, string> = {}): Promise<string> {
	return new Promise((resolve, reject) => {
		const parsed = new URL(url);
		const transport = parsed.protocol === "https:" ? https : http;

		const options = {
			hostname: parsed.hostname,
			port: parsed.port || (parsed.protocol === "https:" ? 443 : 80),
			path: parsed.pathname + parsed.search,
			method: "GET",
			headers: {
				"User-Agent":
					"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
				Accept: "text/html,application/xhtml+xml,*/*;q=0.8",
				"Accept-Language": "en-US,en;q=0.9",
				...extraHeaders,
			},
		};

		const req = transport.request(options, (res) => {
			// Follow a single redirect.
			if (
				res.statusCode &&
				res.statusCode >= 300 &&
				res.statusCode < 400 &&
				res.headers.location
			) {
				fetchUrl(res.headers.location, extraHeaders).then(resolve, reject);
				res.resume();
				return;
			}

			if (!res.statusCode || res.statusCode < 200 || res.statusCode >= 300) {
				reject(new Error(`HTTP ${res.statusCode} for ${url}`));
				res.resume();
				return;
			}

			const chunks: Buffer[] = [];
			res.on("data", (chunk: Buffer) => chunks.push(chunk));
			res.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8")));
			res.on("error", reject);
		});

		req.setTimeout(REQUEST_TIMEOUT_MS, () => {
			req.destroy();
			reject(new Error(`Timeout fetching ${url}`));
		});

		req.on("error", reject);
		req.end();
	});
}

/**
 * Search DuckDuckGo using the HTML interface (no API key required).
 * Parses result titles, URLs, and snippets from the response HTML.
 */
async function searchDuckDuckGo(query: string): Promise<SearchResult[]> {
	const params = new URLSearchParams({ q: query, kl: "us-en" });
	const html = await fetchUrl(`https://html.duckduckgo.com/html/?${params}`, {
		// DuckDuckGo HTML endpoint requires an Accept header to avoid redirects.
		Accept: "text/html",
	});

	const results: SearchResult[] = [];

	// Each result block looks like:
	//   <div class="result__body">
	//     <a class="result__a" href="...">Title</a>
	//     <a class="result__snippet">Snippet text</a>
	//   </div>
	// The href on result__a is a DDG redirect; the real URL is in the href
	// query param `uddg=`.
	const resultBlockRe = /<div class="result__body"[\s\S]*?(?=<div class="result__body"|<\/div><!--end-results-->)/g;
	const titleRe = /<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/;
	const snippetRe = /<a[^>]*class="result__snippet"[^>]*>([\s\S]*?)<\/a>/;

	let block: RegExpExecArray | null;
	while ((block = resultBlockRe.exec(html)) !== null && results.length < MAX_RESULTS) {
		const blockHtml = block[0];

		const titleMatch = titleRe.exec(blockHtml);
		if (!titleMatch) continue;

		const rawHref = titleMatch[1];
		const rawTitle = titleMatch[2].replace(/<[^>]+>/g, "").trim();

		// Resolve the real URL from the DDG redirect link.
		let realUrl = rawHref;
		try {
			const hrefUrl = new URL(rawHref.startsWith("//") ? `https:${rawHref}` : rawHref);
			const uddg = hrefUrl.searchParams.get("uddg");
			if (uddg) realUrl = decodeURIComponent(uddg);
		} catch {
			// Keep rawHref if URL parsing fails.
		}

		const snippetMatch = snippetRe.exec(blockHtml);
		const rawSnippet = snippetMatch
			? snippetMatch[1].replace(/<[^>]+>/g, "").trim()
			: "";

		if (!rawTitle && !rawSnippet) continue;

		results.push({
			title: decodeHtmlEntities(rawTitle),
			url: realUrl,
			snippet: decodeHtmlEntities(rawSnippet),
		});
	}

	return results;
}

/** Decode common HTML entities in search result text. */
function decodeHtmlEntities(text: string): string {
	return text
		.replace(/&amp;/g, "&")
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&quot;/g, '"')
		.replace(/&#39;/g, "'")
		.replace(/&nbsp;/g, " ")
		.replace(/&#x27;/g, "'")
		.replace(/&#x2F;/g, "/");
}

/**
 * Fetch a web page and extract its readable text content.
 * Strips HTML tags, collapses whitespace, and truncates to MAX_PAGE_CHARS.
 */
async function fetchPage(url: string): Promise<string> {
	const html = await fetchUrl(url);

	// Remove script, style, and nav blocks before stripping tags.
	const cleaned = html
		.replace(/<script[\s\S]*?<\/script>/gi, " ")
		.replace(/<style[\s\S]*?<\/style>/gi, " ")
		.replace(/<nav[\s\S]*?<\/nav>/gi, " ")
		.replace(/<header[\s\S]*?<\/header>/gi, " ")
		.replace(/<footer[\s\S]*?<\/footer>/gi, " ")
		.replace(/<[^>]+>/g, " ")
		.replace(/\s{2,}/g, " ")
		.trim();

	if (cleaned.length <= MAX_PAGE_CHARS) return cleaned;
	return cleaned.slice(0, MAX_PAGE_CHARS) + `\n\n[... truncated at ${MAX_PAGE_CHARS} chars]`;
}

/** Format search results as plain text for the LLM. */
function formatResults(results: SearchResult[]): string {
	if (results.length === 0) return "No results found.";
	return results
		.map(
			(r, i) =>
				`${i + 1}. ${r.title}\n   URL: ${r.url}\n   ${r.snippet}`,
		)
		.join("\n\n");
}

export default function webSearchExtension(pi: ExtensionAPI): void {
	// Tool: search the web and return a list of results with titles and snippets.
	pi.registerTool({
		name: "web_search",
		label: "Web Search",
		description:
			"Search the web using DuckDuckGo (no API key required). Returns up to 8 results with titles, URLs, and snippets. Use this when you need current information, documentation, or anything not in your training data.",
		promptSnippet: "Search the web for current information",
		parameters: Type.Object({
			query: Type.String({
				description: "The search query to look up on DuckDuckGo",
			}),
		}),
		async execute(_toolCallId, params, _signal) {
			try {
				const results = await searchDuckDuckGo(params.query);
				return {
					content: [{ type: "text", text: formatResults(results) }],
					details: { query: params.query, resultCount: results.length, results },
				};
			} catch (err) {
				const msg = err instanceof Error ? err.message : String(err);
				return {
					content: [{ type: "text", text: `Search failed: ${msg}` }],
					details: { query: params.query, error: msg },
					isError: true,
				};
			}
		},
	});

	// Tool: fetch a specific URL and return its text content.
	// Useful after a web_search to read the full content of a result.
	pi.registerTool({
		name: "web_fetch",
		label: "Web Fetch",
		description:
			"Fetch the text content of a specific URL. Use after web_search to read the full content of a result page. Returns up to 12,000 characters of readable text.",
		promptSnippet: "Fetch and read a specific URL",
		parameters: Type.Object({
			url: Type.String({
				description: "The full URL to fetch (must start with http:// or https://)",
			}),
		}),
		async execute(_toolCallId, params, _signal) {
			try {
				const text = await fetchPage(params.url);
				return {
					content: [{ type: "text", text }],
					details: { url: params.url, length: text.length },
				};
			} catch (err) {
				const msg = err instanceof Error ? err.message : String(err);
				return {
					content: [{ type: "text", text: `Fetch failed: ${msg}` }],
					details: { url: params.url, error: msg },
					isError: true,
				};
			}
		},
	});
}
