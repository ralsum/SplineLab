const kAppTitle = 'WSEditor';

const editor = document.getElementById('editor');
const titleEl = document.getElementById('title');
const fallbackOpen = document.getElementById('fallbackOpen');

const modalOverlay = document.getElementById('modalOverlay');
const modalBody = document.getElementById('modalBody');
const modalActions = document.getElementById('modalActions');

const state = {
  dirty: false,
  loading: false,
  wordStarPending: false,
  currentFileName: '',
  currentHandle: null,
  fontFamily: 'Courier New',
  fontPointSize: 12,
};

const hasFileSystemAccess =
  'showOpenFilePicker' in window && 'showSaveFilePicker' in window;

function setLoading(v) {
  state.loading = v;
}

function updateTitle() {
  const base = state.currentFileName ? state.currentFileName : 'Untitled';
  titleEl.textContent = `${base}${state.dirty ? ' *' : ''} - ${kAppTitle}`;
  document.title = titleEl.textContent;
}

function normalizeForEdit(text) {
  // Native behavior: \r -> \r\n (and if already \r\n, keep as \r\n), \n -> \r\n
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\n/g, '\r\n');
}

function normalizeForSave(text) {
  // Save with \r\n line endings.
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\n/g, '\r\n');
}

function decodeUtf8Bytes(bytes) {
  let arr = bytes;
  if (arr.length >= 3 && arr[0] === 0xEF && arr[1] === 0xBB && arr[2] === 0xBF) {
    arr = arr.slice(3);
  }
  return new TextDecoder('utf-8', { fatal: false }).decode(arr);
}

function encodeUtf8String(str) {
  return new TextEncoder().encode(str);
}

function showModal({ title, bodyHtml, actions }) {
  modalBody.innerHTML = `${title ? `<div style="font-weight:600;margin-bottom:8px">${escapeHtml(title)}</div>` : ''}${bodyHtml || ''}`;
  modalActions.innerHTML = '';

  modalOverlay.hidden = false;

  return new Promise((resolve) => {
    for (const a of actions) {
      const btn = document.createElement('button');
      if (a.primary) btn.classList.add('primary');
      btn.type = 'button';
      btn.textContent = a.label;
      btn.addEventListener('click', () => {
        modalOverlay.hidden = true;
        resolve(a.value);
      });
      modalActions.appendChild(btn);
    }
  });
}

function escapeHtml(s) {
  return String(s)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function applyFont() {
  // Convert points to px: px = pt * 96/72.
  const px = Math.max(6, state.fontPointSize) * (96 / 72);
  editor.style.fontFamily = state.fontFamily;
  editor.style.fontSize = `${px}px`;
}

function setDirty(v) {
  state.dirty = v;
  updateTitle();
}

editor.addEventListener('input', () => {
  if (state.loading) return;
  setDirty(true);
});

// WordStar Ctrl+K flow
function onEditorKeyDown(e) {
  if (e.defaultPrevented) return;

  // Ctrl+K (start)
  if (!state.wordStarPending) {
    if (e.ctrlKey && !e.altKey && !e.metaKey && e.key && e.key.toLowerCase() === 'k') {
      state.wordStarPending = true;
      e.preventDefault();
      return;
    }
    return;
  }

  // Pending: next single key triggers command
  const key = e.key;
  state.wordStarPending = false;

  if (key.length !== 1) return;
  const vk = key.toUpperCase();

  switch (vk) {
    case 'N':
      e.preventDefault();
      void cmdNew();
      return;
    case 'O':
      e.preventDefault();
      void cmdOpen();
      return;
    case 'S':
      e.preventDefault();
      void cmdSave();
      return;
    case 'A':
      e.preventDefault();
      void cmdSaveAs();
      return;
    case 'F':
      e.preventDefault();
      void cmdFont();
      return;
    case 'Q':
      e.preventDefault();
      void cmdExit();
      return;
    default:
      return;
  }
}

// Ensure the editor keeps focus so keyboard shortcuts work.
editor.addEventListener('mousedown', () => {
  // Let the click happen, then focus.
  setTimeout(() => editor.focus(), 0);
});

// Capture-phase handler to reduce browser/global shortcut interference (e.g. Ctrl+K).
document.addEventListener('keydown', (e) => {
  if (document.activeElement !== editor) return;
  onEditorKeyDown(e);
}, true);

editor.addEventListener('keydown', onEditorKeyDown);

// Menus
for (const menu of document.querySelectorAll('.menu')) {
  const btn = menu.querySelector('.menu-btn');
  btn.addEventListener('click', (e) => {
    e.stopPropagation();
    for (const m of document.querySelectorAll('.menu.open')) {
      if (m !== menu) m.classList.remove('open');
    }
    menu.classList.toggle('open');
  });
}

document.addEventListener('click', () => {
  for (const m of document.querySelectorAll('.menu.open')) m.classList.remove('open');
});

for (const b of document.querySelectorAll('[data-cmd]')) {
  b.addEventListener('click', () => {
    const cmd = b.getAttribute('data-cmd');
    switch (cmd) {
      case 'new': void cmdNew(); break;
      case 'open': void cmdOpen(); break;
      case 'save': void cmdSave(); break;
      case 'saveAs': void cmdSaveAs(); break;
      case 'font': void cmdFont(); break;
      case 'exit': void cmdExit(); break;
      case 'about': void cmdAbout(); break;
    }
  });
}

function getEditorText() {
  return editor.value;
}

async function readFromHandle(handle) {
  const file = await handle.getFile();
  const bytes = new Uint8Array(await file.arrayBuffer());
  return decodeUtf8Bytes(bytes);
}

async function writeToHandle(handle, text) {
  const bytes = encodeUtf8String(normalizeForSave(text));
  const writable = await handle.createWritable();
  await writable.write(bytes);
  await writable.close();
}

async function ensureSavedForTransition() {
  if (!state.dirty) return true;

  const filename = state.currentFileName ? state.currentFileName : 'Untitled';
  const result = await showModal({
    title: 'Save changes?',
    bodyHtml: `"${escapeHtml(filename)}" has unsaved changes.`,
    actions: [
      { label: 'Save', value: 'save', primary: true },
      { label: "Don't Save", value: 'discard' },
      { label: 'Cancel', value: 'cancel' },
    ],
  });

  if (result === 'cancel') return false;
  if (result === 'discard') {
    return true;
  }

  // Save
  const ok = await cmdSave({ quiet: true });
  return ok;
}

async function cmdNew() {
  if (!(await ensureSavedForTransition())) return;

  setLoading(true);
  try {
    editor.value = '';
    state.currentHandle = null;
    state.currentFileName = '';
    setDirty(false);
  } finally {
    setLoading(false);
  }
}

async function openWithFallback() {
  return new Promise((resolve) => {
    fallbackOpen.value = '';
    fallbackOpen.click();

    fallbackOpen.onchange = async () => {
      const file = fallbackOpen.files && fallbackOpen.files[0];
      if (!file) return resolve({ ok: false });
      const bytes = new Uint8Array(await file.arrayBuffer());
      const text = decodeUtf8Bytes(bytes);
      resolve({ ok: true, text, fileName: file.name });
    };
  });
}

async function cmdOpen() {
  if (!(await ensureSavedForTransition())) return;

  if (hasFileSystemAccess) {
    try {
      const pickerOpts = {
        types: [
          { description: 'Text Files', accept: { 'text/plain': ['.txt'] } },
          { description: 'All Files', accept: { '*/*': ['.*'] } },
        ],
        excludeAcceptAllOption: false,
        multiple: false,
      };
      const handles = await window.showOpenFilePicker(pickerOpts);
      if (!handles || handles.length === 0) return;
      const handle = handles[0];
      const text = await readFromHandle(handle);

      setLoading(true);
      try {
        editor.value = normalizeForEdit(text);
        state.currentHandle = handle;
        state.currentFileName = handle.name || '';
        setDirty(false);
      } finally {
        setLoading(false);
      }
      return;
    } catch {
      return;
    }
  }

  const opened = await openWithFallback();
  if (!opened.ok) return;

  setLoading(true);
  try {
    editor.value = normalizeForEdit(opened.text);
    state.currentHandle = null;
    state.currentFileName = opened.fileName || '';
    setDirty(false);
  } finally {
    setLoading(false);
  }
}

async function cmdSave({ quiet } = {}) {
  // If no file chosen yet, Save As.
  if (!state.currentHandle) {
    return await cmdSaveAs({ quiet });
  }

  try {
    await writeToHandle(state.currentHandle, getEditorText());
    state.currentFileName = state.currentFileName || state.currentHandle.name || 'Untitled';
    setDirty(false);
    return true;
  } catch (e) {
    if (!quiet) {
      await showModal({
        title: 'Could not save the file',
        bodyHtml: `Your browser blocked saving or the write failed.`,
        actions: [{ label: 'OK', value: 'ok', primary: true }],
      });
    }
    return false;
  }
}

function downloadBlob(filename, bytes) {
  const blob = new Blob([bytes], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1500);
}

async function cmdSaveAs({ quiet } = {}) {
  const defaultName = state.currentFileName || 'untitled.txt';

  const text = getEditorText();
  if (hasFileSystemAccess) {
    try {
      const opts = {
        suggestedName: defaultName,
        types: [
          { description: 'Text Files', accept: { 'text/plain': ['.txt'] } },
          { description: 'All Files', accept: { '*/*': ['.*'] } },
        ],
      };

      const handle = await window.showSaveFilePicker(opts);
      state.currentHandle = handle;
      state.currentFileName = handle.name || defaultName;
      await writeToHandle(handle, text);
      setDirty(false);
      return true;
    } catch {
      return false;
    }
  }

  // Fallback: download + prompt filename
  const filename = window.prompt('Save as (filename):', defaultName);
  if (!filename) return false;
  const bytes = encodeUtf8String(normalizeForSave(text));
  downloadBlob(filename, bytes);
  state.currentFileName = filename;
  state.currentHandle = null;
  setDirty(false);
  return true;
}

async function cmdExit() {
  if (!(await ensureSavedForTransition())) return;
  // Best effort: close tab if allowed.
  window.close();
}

async function cmdFont() {
  const body = `
    <div class="field">
      <label>Font family</label>
      <select class="input" id="fontFamily">
        ${[
          'Courier New',
          'Consolas',
          'Lucida Console',
          'Menlo',
          'Monaco',
          'Ubuntu Mono',
          'DejaVu Sans Mono',
        ]
          .map((f) => `<option value="${escapeHtml(f)}" ${f === state.fontFamily ? 'selected' : ''}>${escapeHtml(f)}</option>`)
          .join('')}
      </select>
    </div>
    <div class="field">
      <label>Size (points)</label>
      <div class="row">
        <input class="input" id="fontSize" type="number" min="6" step="1" value="${state.fontPointSize}" />
      </div>
    </div>
  `;

  const result = await showModal({
    title: 'Font',
    bodyHtml: body,
    actions: [
      { label: 'Cancel', value: 'cancel' },
      { label: 'Apply', value: 'apply', primary: true },
    ],
  });

  if (result !== 'apply') return;

  const ff = document.getElementById('fontFamily')?.value || state.fontFamily;
  const fs = Number(document.getElementById('fontSize')?.value || state.fontPointSize);

  state.fontFamily = ff;
  state.fontPointSize = Math.max(6, Number.isFinite(fs) ? fs : state.fontPointSize);
  applyFont();
}

async function cmdAbout() {
  await showModal({
    title: 'About',
    bodyHtml: `
      <div style="color:var(--muted);line-height:1.45">
        <div style="margin-bottom:8px">WSEditor</div>
        <div>WordStar-style shortcuts</div>
        <div>Text saved as UTF-8</div>
        <div>Font selection + dirty-save prompts</div>
      </div>
    `,
    actions: [{ label: 'OK', value: 'ok', primary: true }],
  });
}

// Init
applyFont();
setLoading(true);
editor.value = '';
setLoading(false);
updateTitle();

// Close menus on Escape
window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    for (const m of document.querySelectorAll('.menu.open')) m.classList.remove('open');
    state.wordStarPending = false;
  }
});
