// Restores the claude.ai connector route after `bun install`.
const fs = require('fs');

const target = 'node_modules/claudish/dist/index.js';
const routeFragment = 'app.all("/v1/mcp_servers"';
let source = fs.readFileSync(target, 'utf8');

if (source.includes(routeFragment)) {
  console.log('claudish mcp route already present');
} else {
  const marker = '  app.post("/v1/messages/count_tokens"';
  const route = `  app.all("/v1/mcp_servers", async (c) => {
    try {
      const path = c.req.url.slice(c.req.url.indexOf("/v1/"));
      const headers = {};
      for (const name of ["authorization", "x-api-key", "anthropic-beta", "anthropic-version", "user-agent"]) {
        const value = c.req.header(name);
        if (value)
          headers[name] = value;
      }
      return await fetch("https://api.anthropic.com" + path, { method: c.req.method, headers });
    } catch (e) {
      return c.json(wrapAnthropicError(500, String(e)), 500);
    }
  });
`;
  const idx = source.indexOf(marker);
  if (idx < 0) throw new Error('claudish patch marker (/v1/messages/count_tokens) not found. Re-pin the claudish version.');
  source = source.slice(0, idx) + route + source.slice(idx);
  fs.writeFileSync(target, source);
  console.log('patched claudish: claude.ai connector route restored');
}
