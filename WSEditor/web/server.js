/* Minimal static server (no deps) */
const http = require('http');
const fs = require('fs');
const path = require('path');

const port = Number(process.env.PORT || process.argv[2] || 5173);
const root = __dirname;

const mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
};

function send(res, status, body, headers = {}) {
  res.writeHead(status, { ...headers });
  res.end(body);
}

function serveFile(res, filePath) {
  const ext = path.extname(filePath).toLowerCase();
  const type = mime[ext] || 'application/octet-stream';
  fs.readFile(filePath, (err, data) => {
    if (err) return send(res, 404, 'Not found');
    send(res, 200, data, { 'Content-Type': type });
  });
}

const server = http.createServer((req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    let p = decodeURIComponent(url.pathname);
    if (p === '/') p = '/index.html';

    const full = path.normalize(path.join(root, p));
    if (!full.startsWith(root)) return send(res, 403, 'Forbidden');

    if (fs.existsSync(full) && fs.statSync(full).isFile()) {
      return serveFile(res, full);
    }
    // SPA-ish fallback
    const indexPath = path.join(root, 'index.html');
    if (fs.existsSync(indexPath)) {
      return serveFile(res, indexPath);
    }
    return send(res, 404, 'Not found');
  } catch (e) {
    return send(res, 500, 'Server error');
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`WSEditor web server: http://127.0.0.1:${port}/`);
});
