const { app, BrowserWindow, clipboard, globalShortcut, ipcMain, Menu, nativeImage, shell, Tray } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { checkClaim, compareSources, defaultRules, validateRules, webURL } = require('./review.cjs');
const { LocalOllama, ordinaryName } = require('./ollama.cjs');

const index = path.join(__dirname, 'ui', 'index.html');
const pageURL = pathToFileURL(index).href;
const accelerator = 'CommandOrControl+Alt+Shift+J';
const shortcut = process.platform === 'darwin' ? '⌘⌥⇧J' : 'Ctrl+Alt+Shift+J';
const ollama = new LocalOllama();
let window;
let preferences;
let shortcutAvailable = false;
let active;
let tray;
let quitting = false;

function settingsPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}

function loadSettings() {
  const current = settingsPath();
  const appData = app.getPath('appData');
  const usePrevious = app.isPackaged && path.dirname(current) === path.join(appData, app.getName()) &&
    !fs.existsSync(current);
  const saved = usePrevious ? path.join(appData, 'Claim Check', 'settings.json') : current;
  try {
    const value = JSON.parse(fs.readFileSync(saved, 'utf8'));
    return {
      model: ordinaryName(value?.model) ? value.model : '',
      rules: validateRules(value.rules)
    };
  } catch {
    return { model: '', rules: defaultRules };
  }
}

function saveSettings(input) {
  if (input.model !== '' && !ordinaryName(input.model)) throw new Error('Choose an installed local text model.');
  const updated = { model: input.model, rules: validateRules(input.rules) };
  const destination = settingsPath();
  const staged = `${destination}.tmp`;
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(staged, JSON.stringify(updated, null, 2), { mode: 0o600 });
  fs.renameSync(staged, destination);
  preferences = updated;
}

function createWindow() {
  const view = new BrowserWindow({
    width: 740, height: 790, minWidth: 410, minHeight: 440, show: false,
    backgroundColor: '#211a2b',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, sandbox: true, nodeIntegration: false
    }
  });
  window = view;
  view.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  view.webContents.on('will-navigate', event => event.preventDefault());
  view.webContents.session.setPermissionRequestHandler((_sender, _permission, done) => done(false));
  view.webContents.session.setPermissionCheckHandler(() => false);
  view.once('ready-to-show', () => view.show());
  view.on('close', event => {
    if (tray && !quitting && (process.platform !== 'linux' || shortcutAvailable)) {
      event.preventDefault();
      view.hide();
    }
  });
  view.on('closed', () => {
    active?.abort();
    window = undefined;
  });
  void view.loadFile(index);
  return view;
}

function focusWindow() {
  const view = window ?? createWindow();
  if (view.isMinimized()) view.restore();
  view.show();
  view.focus();
  return view;
}

function previewClipboard() {
  const text = clipboard.readText().slice(0, 4801);
  const view = focusWindow();
  const send = () => {
    if (!view.isDestroyed()) view.webContents.send('review:clipboard-preview', text);
  };
  if (view.webContents.isLoadingMainFrame()) view.webContents.once('did-finish-load', send);
  else send();
}

function handle(name, run) {
  ipcMain.handle(`review:${name}`, (event, input) => {
    if (event.sender !== window?.webContents || event.senderFrame?.url !== pageURL) {
      throw new Error('Request came from outside the Hold UP window.');
    }
    return run(input);
  });
}

async function review(input, run) {
  if (active) throw new Error('A review is already running. Cancel it or wait for it to finish.');
  if (!ordinaryName(input?.model)) throw new Error('Choose an installed local text model.');
  const controller = new AbortController();
  active = controller;
  try {
    return await run(input, (prompt, system, schema, signal) =>
      ollama.generate(input.model, prompt, system, schema, signal), controller.signal);
  } finally {
    active = undefined;
  }
}

function setup() {
  preferences = loadSettings();
  handle('init', () => ({ ...preferences, shortcut, shortcutAvailable }));
  handle('models', () => ollama.models());
  handle('settings', saveSettings);
  handle('clipboard', () => clipboard.readText().slice(0, 4801));
  handle('copy-evidence', text => {
    if (typeof text !== 'string' || text.length > 40_000) throw new Error('Evidence is too long to copy.');
    clipboard.writeText(text);
  });
  handle('check', input => review(input, checkClaim));
  handle('evidence', input => review(input, compareSources));
  handle('cancel', () => active?.abort());
  handle('search', query => {
    if (typeof query !== 'string' || !query.trim() || query.length > 4800) throw new Error('Enter a search query.');
    const url = new URL('https://www.google.com/search');
    url.searchParams.set('q', query.trim());
    return shell.openExternal(url.href);
  });
  handle('open-source', url => shell.openExternal(webURL(url)));

  const menu = [
    ...(process.platform === 'darwin' ? [{ role: 'appMenu' }] : []),
    { label: 'File', submenu: [
      { label: 'Preview Clipboard', click: previewClipboard },
      { type: 'separator' },
      { role: 'quit' }
    ] },
    { role: 'editMenu' }
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(menu));
  try {
    shortcutAvailable = globalShortcut.register(accelerator, previewClipboard);
  } catch {
    shortcutAvailable = false;
  }
  try {
    const icon = nativeImage.createFromPath(path.join(__dirname, 'ui', 'icon.png')).resize({ width: 22 });
    tray = new Tray(icon);
    tray.setToolTip('Hold UP');
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: 'Open Hold UP', click: focusWindow },
      { label: 'Preview Clipboard', click: previewClipboard },
      { type: 'separator' },
      { role: 'quit' }
    ]));
    tray.on('click', focusWindow);
  } catch {
    tray?.destroy();
    tray = undefined;
  }
  createWindow();
}

if (app.requestSingleInstanceLock()) {
  app.on('second-instance', () => { if (app.isReady()) focusWindow(); });
  app.on('activate', () => { if (app.isReady()) focusWindow(); });
  app.on('before-quit', () => {
    quitting = true;
    active?.abort();
  });
  app.on('will-quit', () => globalShortcut.unregisterAll());
  app.whenReady().then(setup);
} else {
  app.quit();
}
