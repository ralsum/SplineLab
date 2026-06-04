#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <commdlg.h>
#include <richedit.h>
#include <shellapi.h>

#include <algorithm>
#include <iterator>
#include <string>
#include <vector>

namespace {

constexpr wchar_t kAppClassName[] = L"WSEditorMainWindow";
constexpr wchar_t kAppTitle[] = L"WSEditor";
constexpr wchar_t kDefaultFace[] = L"Courier New";

constexpr UINT kIdFileNew = 1001;
constexpr UINT kIdFileOpen = 1002;
constexpr UINT kIdFileSave = 1003;
constexpr UINT kIdFileSaveAs = 1004;
constexpr UINT kIdFileExit = 1005;
constexpr UINT kIdFormatFont = 1101;
constexpr UINT kIdHelpAbout = 1201;
constexpr UINT kIdEditControl = 2001;

struct LaunchOptions {
  std::wstring openFile;
};

struct AppState {
  HWND hwnd = nullptr;
  HWND edit = nullptr;
  HFONT font = nullptr;
  WNDPROC oldEditProc = nullptr;
  LOGFONTW logFont{};
  int fontPointSize = 12;
  std::wstring currentFile;
  bool dirty = false;
  bool loading = false;
  bool wordStarPending = false;
};

AppState* GetState(HWND hwnd) {
  return reinterpret_cast<AppState*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
}

std::wstring BaseName(const std::wstring& path) {
  const size_t pos = path.find_last_of(L"\\/");
  if (pos == std::wstring::npos) {
    return path;
  }
  return path.substr(pos + 1);
}

std::wstring DirectoryName(const std::wstring& path) {
  const size_t pos = path.find_last_of(L"\\/");
  if (pos == std::wstring::npos) {
    return L".";
  }
  return path.substr(0, pos);
}

std::wstring Utf8BytesToWide(const std::vector<unsigned char>& bytes) {
  if (bytes.empty()) {
    return {};
  }

  const unsigned char* data = bytes.data();
  size_t size = bytes.size();
  if (size >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
    data += 3;
    size -= 3;
  }

  auto convert = [&](UINT codePage, DWORD flags) -> std::wstring {
    const int required = MultiByteToWideChar(
      codePage, flags, reinterpret_cast<const char*>(data),
      static_cast<int>(size), nullptr, 0
    );
    if (required <= 0) {
      return {};
    }
    std::wstring wide(static_cast<size_t>(required), L'\0');
    MultiByteToWideChar(
      codePage, flags, reinterpret_cast<const char*>(data),
      static_cast<int>(size), wide.data(), required
    );
    return wide;
  };

  std::wstring wide = convert(CP_UTF8, MB_ERR_INVALID_CHARS);
  if (!wide.empty() || size == 0) {
    return wide;
  }
  return convert(CP_ACP, 0);
}

std::string WideToUtf8(const std::wstring& text) {
  if (text.empty()) {
    return {};
  }
  const int required = WideCharToMultiByte(
    CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
    nullptr, 0, nullptr, nullptr
  );
  if (required <= 0) {
    return {};
  }
  std::string bytes(static_cast<size_t>(required), '\0');
  WideCharToMultiByte(
    CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
    bytes.data(), required, nullptr, nullptr
  );
  return bytes;
}

std::wstring NormalizeForEdit(std::wstring text) {
  std::wstring normalized;
  normalized.reserve(text.size() + 16);

  for (size_t i = 0; i < text.size(); ++i) {
    const wchar_t ch = text[i];
    if (ch == L'\r') {
      normalized.push_back(L'\r');
      normalized.push_back(L'\n');
      if (i + 1 < text.size() && text[i + 1] == L'\n') {
        ++i;
      }
    } else if (ch == L'\n') {
      normalized.push_back(L'\r');
      normalized.push_back(L'\n');
    } else {
      normalized.push_back(ch);
    }
  }

  return normalized;
}

bool ReadWholeFile(const std::wstring& path, std::vector<unsigned char>& bytes) {
  HANDLE file = CreateFileW(
    path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, nullptr
  );
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }

  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart < 0) {
    CloseHandle(file);
    return false;
  }

  bytes.resize(static_cast<size_t>(size.QuadPart));
  DWORD totalRead = 0;
  while (totalRead < bytes.size()) {
    DWORD chunk = 0;
    if (!ReadFile(
          file, bytes.data() + totalRead,
          static_cast<DWORD>(std::min<size_t>(bytes.size() - totalRead, 1u << 30)),
          &chunk, nullptr)) {
      CloseHandle(file);
      return false;
    }
    if (chunk == 0) {
      break;
    }
    totalRead += chunk;
  }

  bytes.resize(totalRead);
  CloseHandle(file);
  return true;
}

bool WriteWholeFile(const std::wstring& path, const std::vector<unsigned char>& bytes) {
  HANDLE file = CreateFileW(
    path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
    FILE_ATTRIBUTE_NORMAL, nullptr
  );
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }

  DWORD totalWritten = 0;
  while (totalWritten < bytes.size()) {
    DWORD chunk = 0;
    const DWORD toWrite = static_cast<DWORD>(
      std::min<size_t>(bytes.size() - totalWritten, 1u << 30)
    );
    if (!WriteFile(file, bytes.data() + totalWritten, toWrite, &chunk, nullptr)) {
      CloseHandle(file);
      return false;
    }
    if (chunk == 0) {
      break;
    }
    totalWritten += chunk;
  }

  CloseHandle(file);
  return totalWritten == bytes.size();
}

std::wstring GetEditText(HWND edit) {
  const int length = GetWindowTextLengthW(edit);
  if (length <= 0) {
    return {};
  }

  std::wstring text(static_cast<size_t>(length) + 1, L'\0');
  GetWindowTextW(edit, text.data(), length + 1);
  text.resize(static_cast<size_t>(length));
  return text;
}

void SetEditText(HWND edit, const std::wstring& text) {
  SetWindowTextW(edit, text.c_str());
}

void UpdateTitle(AppState& state) {
  std::wstring title;
  if (state.currentFile.empty()) {
    title = L"Untitled";
  } else {
    title = BaseName(state.currentFile);
  }

  if (state.dirty) {
    title += L" *";
  }
  title += L" - ";
  title += kAppTitle;
  SetWindowTextW(state.hwnd, title.c_str());
}

void ApplyFont(AppState& state) {
  if (state.font != nullptr) {
    DeleteObject(state.font);
    state.font = nullptr;
  }

  HDC dc = GetDC(state.hwnd);
  const int dpiY = dc ? GetDeviceCaps(dc, LOGPIXELSY) : 96;
  if (dc) {
    ReleaseDC(state.hwnd, dc);
  }

  state.logFont.lfHeight = -MulDiv(state.fontPointSize, dpiY, 72);
  state.logFont.lfWeight = FW_NORMAL;
  state.logFont.lfCharSet = ANSI_CHARSET;
  state.logFont.lfOutPrecision = OUT_TT_PRECIS;
  state.logFont.lfClipPrecision = CLIP_DEFAULT_PRECIS;
  state.logFont.lfQuality = CLEARTYPE_QUALITY;
  state.logFont.lfPitchAndFamily = FIXED_PITCH | FF_MODERN;
  lstrcpyW(state.logFont.lfFaceName, kDefaultFace);

  state.font = CreateFontIndirectW(&state.logFont);
  SendMessageW(state.edit, WM_SETFONT, reinterpret_cast<WPARAM>(state.font), TRUE);
}

bool PromptToSaveChanges(AppState& state);
bool LoadDocument(AppState& state, const std::wstring& path);
bool SaveDocument(AppState& state, const std::wstring& path);

bool PromptFilePath(HWND owner, bool saveMode, std::wstring& path) {
  wchar_t buffer[32768] = {};
  if (!path.empty()) {
    lstrcpynW(buffer, path.c_str(), static_cast<int>(std::size(buffer)));
  }

  std::wstring initialDirStorage;
  if (!path.empty()) {
    initialDirStorage = DirectoryName(path);
  }

  wchar_t filter[] = L"Text Files (*.txt)\0*.txt\0All Files (*.*)\0*.*\0\0";
  OPENFILENAMEW ofn{};
  ofn.lStructSize = sizeof(ofn);
  ofn.hwndOwner = owner;
  ofn.lpstrFilter = filter;
  ofn.lpstrFile = buffer;
  ofn.nMaxFile = static_cast<DWORD>(std::size(buffer));
  ofn.lpstrDefExt = L"txt";
  ofn.lpstrInitialDir = initialDirStorage.empty() ? nullptr : initialDirStorage.c_str();
  ofn.Flags = OFN_EXPLORER | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY;

  if (saveMode) {
    ofn.Flags |= OFN_OVERWRITEPROMPT;
    if (GetSaveFileNameW(&ofn)) {
      path = buffer;
      return true;
    }
    return false;
  }

  ofn.Flags |= OFN_FILEMUSTEXIST;
  if (GetOpenFileNameW(&ofn)) {
    path = buffer;
    return true;
  }
  return false;
}

void MarkDirty(AppState& state, bool dirty) {
  state.dirty = dirty;
  UpdateTitle(state);
}

bool LoadDocument(AppState& state, const std::wstring& path) {
  std::vector<unsigned char> bytes;
  if (!ReadWholeFile(path, bytes)) {
    MessageBoxW(state.hwnd, L"Could not open the file.", kAppTitle, MB_ICONERROR | MB_OK);
    return false;
  }

  state.loading = true;
  const std::wstring text = NormalizeForEdit(Utf8BytesToWide(bytes));
  SetEditText(state.edit, text);
  state.loading = false;

  state.currentFile = path;
  MarkDirty(state, false);
  return true;
}

bool SaveDocument(AppState& state, const std::wstring& path) {
  const std::wstring text = GetEditText(state.edit);
  const std::string utf8 = WideToUtf8(text);
  const std::vector<unsigned char> bytes(utf8.begin(), utf8.end());

  if (!WriteWholeFile(path, bytes)) {
    MessageBoxW(state.hwnd, L"Could not save the file.", kAppTitle, MB_ICONERROR | MB_OK);
    return false;
  }

  state.currentFile = path;
  MarkDirty(state, false);
  return true;
}

bool SaveDocumentWithPrompt(AppState& state, bool forceSaveAs) {
  std::wstring path = state.currentFile;
  if (forceSaveAs || path.empty()) {
    if (!PromptFilePath(state.hwnd, true, path)) {
      return false;
    }
  }
  return SaveDocument(state, path);
}

bool PromptToSaveChanges(AppState& state) {
  if (!state.dirty) {
    return true;
  }

  const int response = MessageBoxW(
    state.hwnd,
    L"Save changes before continuing?",
    kAppTitle,
    MB_ICONQUESTION | MB_YESNOCANCEL
  );

  if (response == IDCANCEL) {
    return false;
  }
  if (response == IDYES) {
    return SaveDocumentWithPrompt(state, false);
  }
  return true;
}

void NewDocument(AppState& state) {
  if (!PromptToSaveChanges(state)) {
    return;
  }

  state.loading = true;
  SetEditText(state.edit, L"");
  state.loading = false;
  state.currentFile.clear();
  MarkDirty(state, false);
}

void OpenDocument(AppState& state) {
  if (!PromptToSaveChanges(state)) {
    return;
  }

  std::wstring path = state.currentFile;
  if (!PromptFilePath(state.hwnd, false, path)) {
    return;
  }
  LoadDocument(state, path);
}

void SaveCurrentDocument(AppState& state) {
  SaveDocumentWithPrompt(state, false);
}

void SaveCurrentDocumentAs(AppState& state) {
  SaveDocumentWithPrompt(state, true);
}

void PickFont(AppState& state) {
  CHOOSEFONTW cf{};
  cf.lStructSize = sizeof(cf);
  cf.hwndOwner = state.hwnd;
  cf.lpLogFont = &state.logFont;
  cf.Flags = CF_SCREENFONTS | CF_INITTOLOGFONTSTRUCT | CF_EFFECTS | CF_FORCEFONTEXIST;
  cf.nFontType = SCREEN_FONTTYPE;
  cf.iPointSize = state.fontPointSize * 10;

  if (ChooseFontW(&cf)) {
    state.logFont = *cf.lpLogFont;
    if (cf.iPointSize > 0) {
      state.fontPointSize = std::max(6, cf.iPointSize / 10);
    }
    ApplyFont(state);
  }
}

void ShowAbout(HWND hwnd) {
  MessageBoxW(
    hwnd,
    L"WSEditor\n\nA lightweight WordStar-style editor skeleton.\n"
    L"Current build stores text as UTF-8 on save and is ASCII-safe.",
    kAppTitle,
    MB_ICONINFORMATION | MB_OK
  );
}

bool HandleWordStarKey(AppState& state, UINT vk) {
  if (!state.wordStarPending) {
    if ((GetKeyState(VK_CONTROL) & 0x8000) != 0 && vk == 'K') {
      state.wordStarPending = true;
      return true;
    }
    return false;
  }

  state.wordStarPending = false;
  switch (vk) {
    case 'N': NewDocument(state); return true;
    case 'O': OpenDocument(state); return true;
    case 'S': SaveCurrentDocument(state); return true;
    case 'A': SaveCurrentDocumentAs(state); return true;
    case 'F': PickFont(state); return true;
    case 'Q': PostMessageW(state.hwnd, WM_CLOSE, 0, 0); return true;
    default: return false;
  }
}

LRESULT CALLBACK EditProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  HWND parent = GetParent(hwnd);
  AppState* state = parent ? GetState(parent) : nullptr;

  if (state != nullptr) {
    if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
      if (HandleWordStarKey(*state, static_cast<UINT>(wParam))) {
        return 0;
      }
    }
  }

  if (state != nullptr && state->oldEditProc != nullptr) {
    return CallWindowProcW(state->oldEditProc, hwnd, msg, wParam, lParam);
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

HMENU CreateAppMenu() {
  HMENU menuBar = CreateMenu();
  HMENU fileMenu = CreatePopupMenu();
  HMENU formatMenu = CreatePopupMenu();
  HMENU helpMenu = CreatePopupMenu();

  AppendMenuW(fileMenu, MF_STRING, kIdFileNew, L"&New\tCtrl+K N");
  AppendMenuW(fileMenu, MF_STRING, kIdFileOpen, L"&Open...\tCtrl+K O");
  AppendMenuW(fileMenu, MF_STRING, kIdFileSave, L"&Save\tCtrl+K S");
  AppendMenuW(fileMenu, MF_STRING, kIdFileSaveAs, L"Save &As...\tCtrl+K A");
  AppendMenuW(fileMenu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(fileMenu, MF_STRING, kIdFileExit, L"E&xit\tCtrl+K Q");

  AppendMenuW(formatMenu, MF_STRING, kIdFormatFont, L"&Font...\tCtrl+K F");

  AppendMenuW(helpMenu, MF_STRING, kIdHelpAbout, L"&About");

  AppendMenuW(menuBar, MF_POPUP, reinterpret_cast<UINT_PTR>(fileMenu), L"&File");
  AppendMenuW(menuBar, MF_POPUP, reinterpret_cast<UINT_PTR>(formatMenu), L"&Format");
  AppendMenuW(menuBar, MF_POPUP, reinterpret_cast<UINT_PTR>(helpMenu), L"&Help");
  return menuBar;
}

void LayoutChild(AppState& state) {
  RECT rc{};
  GetClientRect(state.hwnd, &rc);
  MoveWindow(state.edit, 0, 0, rc.right - rc.left, rc.bottom - rc.top, TRUE);
}

void InitializeDefaultFont(AppState& state) {
  ZeroMemory(&state.logFont, sizeof(state.logFont));
  lstrcpyW(state.logFont.lfFaceName, kDefaultFace);
  state.logFont.lfCharSet = ANSI_CHARSET;
  state.logFont.lfPitchAndFamily = FIXED_PITCH | FF_MODERN;
}

}  // namespace

LRESULT CALLBACK MainProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  AppState* state = GetState(hwnd);

  switch (msg) {
    case WM_CREATE: {
      const auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
      const auto* launch = reinterpret_cast<const LaunchOptions*>(cs->lpCreateParams);

      auto* createdState = new AppState();
      createdState->hwnd = hwnd;
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(createdState));
      state = createdState;

      SetMenu(hwnd, CreateAppMenu());

      HMODULE richEdit = LoadLibraryW(L"Msftedit.dll");
      if (richEdit == nullptr) {
        MessageBoxW(hwnd, L"Could not load Msftedit.dll.", kAppTitle, MB_ICONERROR | MB_OK);
        delete createdState;
        return -1;
      }

      state->edit = CreateWindowExW(
        WS_EX_CLIENTEDGE,
        MSFTEDIT_CLASS,
        L"",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | WS_HSCROLL |
          ES_MULTILINE | ES_AUTOVSCROLL | ES_AUTOHSCROLL | ES_WANTRETURN | ES_NOHIDESEL,
        0, 0, 0, 0,
        hwnd,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(kIdEditControl)),
        GetModuleHandleW(nullptr),
        nullptr
      );

      if (state->edit == nullptr) {
        MessageBoxW(hwnd, L"Could not create the editor control.", kAppTitle, MB_ICONERROR | MB_OK);
        delete createdState;
        return -1;
      }

      state->oldEditProc = reinterpret_cast<WNDPROC>(
        SetWindowLongPtrW(state->edit, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(EditProc))
      );

      SendMessageW(state->edit, EM_EXLIMITTEXT, 0, 0x7fffffff);

      InitializeDefaultFont(*state);
      ApplyFont(*state);
      UpdateTitle(*state);
      LayoutChild(*state);

      if (launch != nullptr && !launch->openFile.empty()) {
        LoadDocument(*state, launch->openFile);
      }
      return 0;
    }

    case WM_SIZE:
      if (state != nullptr && state->edit != nullptr) {
        LayoutChild(*state);
      }
      return 0;

    case WM_SETFOCUS:
      if (state != nullptr && state->edit != nullptr) {
        SetFocus(state->edit);
      }
      return 0;

    case WM_COMMAND:
      if (state == nullptr) {
        return 0;
      }

      switch (LOWORD(wParam)) {
        case kIdFileNew: NewDocument(*state); return 0;
        case kIdFileOpen: OpenDocument(*state); return 0;
        case kIdFileSave: SaveCurrentDocument(*state); return 0;
        case kIdFileSaveAs: SaveCurrentDocumentAs(*state); return 0;
        case kIdFileExit: SendMessageW(hwnd, WM_CLOSE, 0, 0); return 0;
        case kIdFormatFont: PickFont(*state); return 0;
        case kIdHelpAbout: ShowAbout(hwnd); return 0;
        case kIdEditControl:
          if (HIWORD(wParam) == EN_CHANGE && !state->loading) {
            MarkDirty(*state, true);
          }
          return 0;
      }
      return 0;

    case WM_CLOSE:
      if (state != nullptr && !PromptToSaveChanges(*state)) {
        return 0;
      }
      DestroyWindow(hwnd);
      return 0;

    case WM_DESTROY:
      if (state != nullptr) {
        if (state->font != nullptr) {
          DeleteObject(state->font);
          state->font = nullptr;
        }
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        delete state;
      }
      PostQuitMessage(0);
      return 0;
  }

  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE, LPWSTR, int showCommand) {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  LaunchOptions launch{};
  if (argv != nullptr && argc > 1 && argv[1] != nullptr) {
    launch.openFile = argv[1];
  }
  if (argv != nullptr) {
    LocalFree(argv);
  }

  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = MainProc;
  wc.hInstance = instance;
  wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  wc.hCursor = LoadCursorW(nullptr, IDC_IBEAM);
  wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  wc.lpszClassName = kAppClassName;
  wc.hIconSm = LoadIconW(nullptr, IDI_APPLICATION);

  if (!RegisterClassExW(&wc)) {
    MessageBoxW(nullptr, L"Could not register the window class.", kAppTitle, MB_ICONERROR | MB_OK);
    return 1;
  }

  HWND hwnd = CreateWindowExW(
    0,
    kAppClassName,
    L"Untitled - WSEditor",
    WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
    CW_USEDEFAULT, CW_USEDEFAULT, 900, 700,
    nullptr,
    nullptr,
    instance,
    &launch
  );

  if (hwnd == nullptr) {
    MessageBoxW(nullptr, L"Could not create the main window.", kAppTitle, MB_ICONERROR | MB_OK);
    return 1;
  }

  ShowWindow(hwnd, showCommand);
  UpdateWindow(hwnd);

  MSG msg{};
  while (GetMessageW(&msg, nullptr, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  return static_cast<int>(msg.wParam);
}
