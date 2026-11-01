import json
import os
import subprocess
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "Resources" / "ui"
PORT = 8765

MOCK = r"""
(() => {
  const srv = { sessions: [], msgs: {} };
  function route(method, path, body) {
    const u = new URL('http://x' + path);
    const p = u.pathname;
    if (p === '/config/providers') return {
      providers: [{ id: 'opencode', name: 'OpenCode Zen', models: {
        'big-pickle': { id: 'big-pickle', name: 'Big Pickle', limit: { context: 200000 }, cost: { input: 0, output: 0 } }
      }}],
      default: { opencode: 'big-pickle' }
    };
    if (p === '/config') return { model: 'opencode/big-pickle', mcp: {}, plugin: [], plugins: [], permissions: [] };
    if (p === '/agent') return [{ name: 'build', mode: 'primary', description: 'build' }];
    if (p === '/command') return [];
    if (p === '/project/current') return { id: 'local', worktree: '/docs', name: 'OpenCode' };
    if (p === '/project') return [{ id: 'local', worktree: '/docs', name: 'OpenCode' }];
    if (p === '/vcs') return { branch: '' };
    if (p === '/experimental/console/orgs') return { orgs: [] };
    if (p === '/session/status') return {};
    if (p === '/session' && method === 'GET') return srv.sessions;
    if (p === '/session' && method === 'POST') {
      const s = { id: 'ses_1', title: 'Новая сессия', time: { created: Date.now(), updated: Date.now() }, directory: '/docs' };
      srv.sessions.unshift(s); srv.msgs[s.id] = [];
      setTimeout(() => OCEvent('sse', { t: 'data', d: JSON.stringify({ directory: '/docs', payload: { type: 'session.created', properties: { info: s } } }) }), 10);
      return s;
    }
    if (/\/session\/[^/]+\/message$/.test(p)) return srv.msgs[p.split('/')[2]] || [];
    if (/\/session\/[^/]+\/(todo|diff)$/.test(p)) return [];
    if (p === '/file') return [
      { name: 'config.json', path: 'config.json', absolute: '/docs/config.json', type: 'file', ignored: false },
      { name: 'AGENTS.md', path: 'AGENTS.md', absolute: '/docs/AGENTS.md', type: 'file', ignored: false }
    ];
    if (p === '/file/status') return [];
    if (p === '/file/content') return { type: 'text', content: '{\n  "model": "opencode/big-pickle"\n}\n' };
    if (p === '/find/file') return [];
    if (p === '/permission' || p === '/question') return [];
    if (p === '/mcp') return {};
    if (p === '/lsp') return [];
    return {};
  }
  window.__srv = srv;
  window.prompt = function(prompt) {
    if (!prompt || !prompt.startsWith('__oc__')) return null;
    let req;
    try { req = JSON.parse(prompt.slice(6)); } catch (e) { return null; }
    const op = req.op, args = req.args || [];
    if (op === 'state') return JSON.stringify({
      version: '1.0.0', code: 1, user: 'Локальный режим', name: 'OpenCode iPhone',
      guest: true, installed: true, ready: true, core: 'on-device',
      perms: { notifications: false, files: true, install: true, battery: true },
      flags: { snd_done: true, snd_action: true, snd_quota: true }, ios: true
    });
    if (op === 'http') {
      const id = args[0], method = args[1], path = args[2], body = args[3];
      let data;
      try { data = route(method, path, body); } catch (e) { data = { error: String(e) }; }
      setTimeout(() => OCEvent('http', { id, status: 200, ct: 'application/json', body: JSON.stringify(data) }), 5);
      return null;
    }
    if (op === 'sseStart') {
      setTimeout(() => OCEvent('sse', { t: 'open' }), 5);
      setTimeout(() => OCEvent('sse', { t: 'data', d: JSON.stringify({ directory: '/docs', payload: { type: 'server.connected', properties: {} } }) }), 10);
      return null;
    }
    if (op === 'sseStop' || op === 'drop' || op === 'wsClose') return null;
    if (op === 'ls') return JSON.stringify({ ok: true, items: [{ name: 'config.json', dir: false }] });
    if (op === 'fs' || op === 'writeText' || op === 'copy' || op === 'share' || op === 'openLink' || op === 'testSound' || op === 'setFlag') return JSON.stringify({ ok: true });
    if (op === 'readText') return JSON.stringify({ ok: true, text: '{\n  "model": "opencode/big-pickle"\n}\n' });
    if (op === 'cfgRead') return JSON.stringify({ model: 'opencode/big-pickle', mcp: {}, plugin: [], permissions: [] }, null, 2);
    if (op === 'cfgWrite') return JSON.stringify({ ok: true });
    if (op === 'readLog') return 'mock log';
    if (op === 'pasteText') return '';
    if (op === 'authLogin' || op === 'authCancel' || op === 'authLogout') return null;
    return null;
  };
})();
"""


def main():
    server = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(PORT), "--directory", str(UI)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    errors = []
    try:
        time.sleep(0.8)
        with sync_playwright() as p:
            browser = p.chromium.launch(args=["--no-sandbox"])
            page = browser.new_page(viewport={"width": 390, "height": 844}, device_scale_factor=2,
                                    is_mobile=True, has_touch=True)
            page.on("pageerror", lambda e: errors.append("pageerror: " + str(e)))
            page.on("console", lambda m: errors.append("console: " + m.text) if m.type == "error" else None)
            page.add_init_script(MOCK)
            page.goto(f"http://127.0.0.1:{PORT}/index.html", wait_until="domcontentloaded")
            page.wait_for_selector("#boot", timeout=8000)
            page.click("text=Начать")
            page.wait_for_selector("#top", timeout=8000)
            page.wait_for_timeout(900)
            assert page.query_selector("#tabbar"), "tabbar missing"
            assert page.query_selector("#msgs .empty"), "empty state missing"
            assert "Big Pickle" in page.inner_text("#composer"), "model chip missing"
            # open settings and the config editor
            page.click("#top button:last-child")
            page.wait_for_selector(".sheet", timeout=5000)
            page.wait_for_timeout(300)
            assert "config.json" in page.inner_text(".sheet"), "config row missing"
            page.locator(".sheet button:has-text('config.json')").first.click()
            page.wait_for_timeout(500)
            sheet = page.query_selector(".sheet")
            assert sheet is not None, "config sheet missing"
            ta = page.locator(".sheet textarea").last
            assert "model" in ta.input_value(), "config content missing"
            page.screenshot(path=str(ROOT / "tests" / "ui_smoke.png"))
            browser.close()
        if errors:
            print("UI ERRORS:")
            for e in errors:
                print(" -", e)
            return 1
        print("UI SMOKE OK")
        return 0
    finally:
        server.terminate()
        server.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())