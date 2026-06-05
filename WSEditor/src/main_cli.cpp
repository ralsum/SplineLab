#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <vector>

namespace {

constexpr int kTabWidth = 4;

enum class KeyType {
  Char,
  CtrlKey,
  Undo,
  ArrowLeft,
  ArrowRight,
  ArrowUp,
  ArrowDown,
  Home,
  End,
  PageUp,
  PageDown,
  Delete,
  Backspace,
  Enter,
  Escape,
  Unknown,
};

struct Key {
  KeyType type = KeyType::Unknown;
  char ch = '\0';
};

struct TerminalSize {
  int rows = 24;
  int cols = 80;
};

struct CursorPos {
  int y = 0;
  int x = 0;
};

enum class PrefixMode {
  None,
  K,
  Q,
  P,
};

class RawTerminal {
 public:
  RawTerminal() {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
      return;
    }

    if (tcgetattr(STDIN_FILENO, &original_) == -1) {
      return;
    }

    termios raw = original_;
    raw.c_iflag &= static_cast<tcflag_t>(~(BRKINT | ICRNL | INPCK | ISTRIP | IXON));
    raw.c_oflag &= static_cast<tcflag_t>(~(OPOST));
    raw.c_cflag |= CS8;
    raw.c_lflag &= static_cast<tcflag_t>(~(ECHO | ICANON | IEXTEN | ISIG));
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 1;

    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == -1) {
      return;
    }

    active_ = true;
    std::cout << "\x1b[?25l" << std::flush;
  }

  RawTerminal(const RawTerminal&) = delete;
  RawTerminal& operator=(const RawTerminal&) = delete;

  ~RawTerminal() {
    if (!active_) {
      return;
    }
    std::cout << "\x1b[?25h\x1b[0m" << std::flush;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &original_);
  }

  bool active() const {
    return active_;
  }

  TerminalSize size() const {
    winsize ws{};
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == -1 || ws.ws_col == 0 || ws.ws_row == 0) {
      return {};
    }
    return {static_cast<int>(ws.ws_row), static_cast<int>(ws.ws_col)};
  }

 private:
  termios original_{};
  bool active_ = false;
};

std::string TrimTrailingCarriageReturns(std::string text) {
  while (!text.empty() && (text.back() == '\r' || text.back() == '\n')) {
    text.pop_back();
  }
  return text;
}

std::string NormalizeNewlines(std::string text) {
  std::string normalized;
  normalized.reserve(text.size());
  for (size_t i = 0; i < text.size(); ++i) {
    const char ch = text[i];
    if (ch == '\r') {
      normalized.push_back('\n');
      if (i + 1 < text.size() && text[i + 1] == '\n') {
        ++i;
      }
    } else {
      normalized.push_back(ch);
    }
  }
  return normalized;
}

std::vector<std::string> SplitLines(const std::string& text) {
  std::vector<std::string> lines;
  std::string current;

  for (char ch : text) {
    if (ch == '\n') {
      lines.push_back(current);
      current.clear();
    } else {
      current.push_back(ch);
    }
  }

  lines.push_back(current);
  if (lines.empty()) {
    lines.emplace_back();
  }
  return lines;
}

std::string JoinLines(const std::vector<std::string>& lines) {
  std::string out;
  for (size_t i = 0; i < lines.size(); ++i) {
    out += lines[i];
    if (i + 1 < lines.size()) {
      out.push_back('\n');
    }
  }
  return out;
}

std::string BaseName(const std::filesystem::path& path) {
  const std::string name = path.filename().string();
  if (name.empty()) {
    return "[No Name]";
  }
  return name;
}

std::string ReadAll(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    return {};
  }

  std::ostringstream buffer;
  buffer << in.rdbuf();
  return buffer.str();
}

bool WriteAll(const std::filesystem::path& path, const std::string& text) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out) {
    return false;
  }
  out << text;
  return static_cast<bool>(out);
}

std::filesystem::path DataDir() {
  const char* home = std::getenv("HOME");
  if (home == nullptr || *home == '\0') {
    return ".";
  }
  return std::filesystem::path(home) / ".local" / "share" / "wse";
}

std::filesystem::path ClipboardCachePath() {
  return DataDir() / "clipboard.txt";
}

std::filesystem::path BlockStatePath() {
  return DataDir() / "block_state.txt";
}

std::string TrimNewlines(std::string text) {
  while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
    text.pop_back();
  }
  return text;
}

std::string ToLowerCopy(std::string text) {
  for (char& ch : text) {
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  }
  return text;
}

std::optional<std::string> RunCommandRead(const std::string& command) {
  FILE* pipe = popen(command.c_str(), "r");
  if (pipe == nullptr) {
    return std::nullopt;
  }

  std::string out;
  std::array<char, 4096> buffer{};
  while (true) {
    const size_t n = std::fread(buffer.data(), 1, buffer.size(), pipe);
    if (n == 0) {
      break;
    }
    out.append(buffer.data(), n);
  }

  const int rc = pclose(pipe);
  if (rc != 0 && out.empty()) {
    return std::nullopt;
  }
  return out;
}

bool RunCommandWrite(const std::string& command, const std::string& data) {
  FILE* pipe = popen(command.c_str(), "w");
  if (pipe == nullptr) {
    return false;
  }

  const size_t written = std::fwrite(data.data(), 1, data.size(), pipe);
  const int rc = pclose(pipe);
  return written == data.size() && rc == 0;
}

std::optional<std::string> ReadAllText(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    return std::nullopt;
  }
  std::ostringstream buffer;
  buffer << in.rdbuf();
  return buffer.str();
}

std::optional<std::string> SystemClipboardPaste() {
  const std::vector<std::string> commands = {
      "wl-paste --no-newline 2>/dev/null",
      "xclip -selection clipboard -o 2>/dev/null",
      "xsel --clipboard --output 2>/dev/null",
      "pbpaste 2>/dev/null",
  };

  for (const auto& command : commands) {
    auto value = RunCommandRead(command);
    if (value.has_value() && !value->empty()) {
      return TrimNewlines(*value);
    }
  }
  return std::nullopt;
}

bool SystemClipboardCopy(const std::string& text) {
  const std::vector<std::string> commands = {
      "wl-copy 2>/dev/null",
      "xclip -selection clipboard 2>/dev/null",
      "xsel --clipboard --input 2>/dev/null",
      "pbcopy 2>/dev/null",
  };

  for (const auto& command : commands) {
    if (RunCommandWrite(command, text)) {
      return true;
    }
  }
  return false;
}

int RenderX(const std::string& line, int cx) {
  int rx = 0;
  const int limit = std::min<int>(cx, static_cast<int>(line.size()));
  for (int i = 0; i < limit; ++i) {
    if (line[static_cast<size_t>(i)] == '\t') {
      rx += kTabWidth - (rx % kTabWidth);
    } else {
      ++rx;
    }
  }
  return rx;
}

int CursorXFromRenderX(const std::string& line, int rx) {
  int current_rx = 0;
  for (int i = 0; i < static_cast<int>(line.size()); ++i) {
    const char ch = line[static_cast<size_t>(i)];
    const int width = (ch == '\t') ? (kTabWidth - (current_rx % kTabWidth)) : 1;
    if (current_rx + width > rx) {
      return i;
    }
    current_rx += width;
  }
  return static_cast<int>(line.size());
}

std::string RenderLine(
    const std::string& line,
    int start_rx,
    int width,
    int line_start_index,
    int selection_start = -1,
    int selection_end = -1) {
  std::string out;
  out.reserve(static_cast<size_t>(width));

  int current_rx = 0;
  int visible_count = 0;
  bool highlight = false;
  auto setHighlight = [&](bool active) {
    if (highlight == active) {
      return;
    }
    out += active ? "\x1b[7m" : "\x1b[m";
    highlight = active;
  };

  for (int i = 0; i < static_cast<int>(line.size()); ++i) {
    const char ch = line[static_cast<size_t>(i)];
    const int char_width = (ch == '\t') ? (kTabWidth - (current_rx % kTabWidth)) : 1;
    if (current_rx + char_width <= start_rx) {
      current_rx += char_width;
      continue;
    }
    if (current_rx >= start_rx + width) {
      break;
    }

    const int global_index = line_start_index + i;
    const bool selected = selection_start >= 0 && selection_end > selection_start &&
                          global_index >= selection_start && global_index < selection_end;
    setHighlight(selected);

    if (ch == '\t') {
      for (int i = 0; i < char_width && visible_count < width; ++i) {
        out.push_back(' ');
        ++visible_count;
      }
    } else {
      out.push_back(ch);
      ++visible_count;
    }
    current_rx += char_width;
  }

  if (visible_count < width) {
    out.append(static_cast<size_t>(width - visible_count), ' ');
  }

  if (highlight) {
    out += "\x1b[m";
  }

  return out;
}

class Editor {
 public:
  explicit Editor(std::filesystem::path initial_file)
      : file_path_(std::move(initial_file)) {
    if (!file_path_.empty()) {
      loadFile(file_path_);
    }
    if (lines_.empty()) {
      lines_.push_back({});
    }
    loadClipboardCache();
    restoreBlockStateForCurrentFile();
    setStatus("Ctrl+K/N/Q/P prefixes; Ctrl+E/X/S/D/A/F/R/C/W/Z nav; Ctrl+V paste");
  }

  void run() {
    while (!quit_) {
      refreshScreen();
      Key key = readKey();
      handleKey(key);
    }
  }

 private:
  std::vector<std::string> lines_ = {""};
  struct Snapshot {
    std::vector<std::string> lines;
    std::filesystem::path file_path;
    bool dirty = false;
    int cursor_x = 0;
    int cursor_y = 0;
    int row_offset = 0;
    int col_offset = 0;
    int preferred_rx = 0;
    std::optional<CursorPos> block_anchor;
    std::optional<CursorPos> block_end;
    bool bold_active = false;
    bool underline_active = false;
  };

  std::vector<Snapshot> undo_stack_;
  std::filesystem::path file_path_;
  bool dirty_ = false;
  bool quit_ = false;
  PrefixMode prefix_mode_ = PrefixMode::None;
  std::optional<CursorPos> block_anchor_;
  std::optional<CursorPos> block_end_;
  std::string clipboard_cache_;
  std::string last_find_query_;
  bool bold_active_ = false;
  bool underline_active_ = false;
  int cursor_x_ = 0;
  int cursor_y_ = 0;
  int row_offset_ = 0;
  int col_offset_ = 0;
  int preferred_rx_ = 0;
  std::string status_message_;
  std::string prompt_message_;

  void setStatus(std::string text) {
    status_message_ = std::move(text);
  }

  void setPrompt(std::string text) {
    prompt_message_ = std::move(text);
  }

  bool isDirty() const {
    return dirty_;
  }

  std::string currentDisplayName() const {
    return file_path_.empty() ? std::string("[No Name]") : BaseName(file_path_);
  }

  void markDirty(bool dirty = true) {
    dirty_ = dirty;
  }

  void pushUndoSnapshot() {
    if (undo_stack_.size() >= 128) {
      undo_stack_.erase(undo_stack_.begin());
    }
    undo_stack_.push_back(Snapshot{
        lines_,
        file_path_,
        dirty_,
        cursor_x_,
        cursor_y_,
        row_offset_,
        col_offset_,
        preferred_rx_,
        block_anchor_,
        block_end_,
        bold_active_,
        underline_active_,
    });
  }

  void restoreSnapshot(const Snapshot& snapshot) {
    lines_ = snapshot.lines;
    if (lines_.empty()) {
      lines_.push_back({});
    }
    file_path_ = snapshot.file_path;
    dirty_ = snapshot.dirty;
    cursor_x_ = snapshot.cursor_x;
    cursor_y_ = snapshot.cursor_y;
    row_offset_ = snapshot.row_offset;
    col_offset_ = snapshot.col_offset;
    preferred_rx_ = snapshot.preferred_rx;
    block_anchor_ = snapshot.block_anchor;
    block_end_ = snapshot.block_end;
    bold_active_ = snapshot.bold_active;
    underline_active_ = snapshot.underline_active;
    ensureCursorInRange();
    updatePreferredRx();
  }

  void undoLastAction() {
    if (undo_stack_.empty()) {
      setStatus("Nothing to undo");
      return;
    }

    const Snapshot snapshot = undo_stack_.back();
    undo_stack_.pop_back();
    restoreSnapshot(snapshot);
    setStatus("Undid previous action");
  }

  void ensureDataDir() {
    std::error_code ec;
    std::filesystem::create_directories(DataDir(), ec);
  }

  void loadClipboardCache() {
    const auto text = ReadAllText(ClipboardCachePath());
    clipboard_cache_ = text.has_value() ? *text : std::string{};
  }

  void saveClipboardCache(const std::string& text) {
    ensureDataDir();
    clipboard_cache_ = text;
    WriteAll(ClipboardCachePath(), clipboard_cache_);
  }

  void saveBlockState() {
    ensureDataDir();
    if (!hasBlockRange() || file_path_.empty()) {
      WriteAll(BlockStatePath(), "");
      return;
    }

    const auto [lo, hi] = blockRange();
    std::ostringstream out;
    out << std::quoted(file_path_.string()) << ' '
        << lo.y << ' ' << lo.x << ' '
        << hi.y << ' ' << hi.x << '\n';
    WriteAll(BlockStatePath(), out.str());
  }

  void restoreBlockStateForCurrentFile() {
    block_anchor_.reset();
    block_end_.reset();
    if (file_path_.empty()) {
      return;
    }

    const auto text = ReadAllText(BlockStatePath());
    if (!text.has_value() || text->empty()) {
      return;
    }

    std::istringstream in(*text);
    std::string saved_path;
    CursorPos lo{};
    CursorPos hi{};
    if (!(in >> std::quoted(saved_path) >> lo.y >> lo.x >> hi.y >> hi.x)) {
      return;
    }

    if (saved_path == file_path_.string()) {
      block_anchor_ = lo;
      block_end_ = hi;
      setStatus("Restored block selection");
    }
  }

  void ensureCursorInRange() {
    if (cursor_y_ < 0) {
      cursor_y_ = 0;
    }
    if (cursor_y_ >= static_cast<int>(lines_.size())) {
      cursor_y_ = static_cast<int>(lines_.size()) - 1;
    }
    if (cursor_y_ < 0) {
      cursor_y_ = 0;
    }

    const int line_length = static_cast<int>(lines_[static_cast<size_t>(cursor_y_)].size());
    if (cursor_x_ < 0) {
      cursor_x_ = 0;
    }
    if (cursor_x_ > line_length) {
      cursor_x_ = line_length;
    }
  }

  void updatePreferredRx() {
    preferred_rx_ = RenderX(lines_[static_cast<size_t>(cursor_y_)], cursor_x_);
  }

  void scrollIntoView(int rows, int cols) {
    const int text_rows = std::max(1, rows - 2);
    const int rx = RenderX(lines_[static_cast<size_t>(cursor_y_)], cursor_x_);

    if (cursor_y_ < row_offset_) {
      row_offset_ = cursor_y_;
    }
    if (cursor_y_ >= row_offset_ + text_rows) {
      row_offset_ = cursor_y_ - text_rows + 1;
    }

    if (rx < col_offset_) {
      col_offset_ = rx;
    }
    if (rx >= col_offset_ + cols) {
      col_offset_ = rx - cols + 1;
    }

    if (row_offset_ < 0) {
      row_offset_ = 0;
    }
    if (col_offset_ < 0) {
      col_offset_ = 0;
    }
  }

  void refreshScreen() {
    const TerminalSize size = terminalSize();
    const int rows = std::max(3, size.rows);
    const int cols = std::max(20, size.cols);
    scrollIntoView(rows, cols);
    const bool has_block = hasBlockRange();
    const auto [sel_lo, sel_hi] = has_block ? blockRange() : std::pair<CursorPos, CursorPos>{currentPos(), currentPos()};
    const int selection_start = has_block ? linearIndex(sel_lo) : -1;
    const int selection_end = has_block ? linearIndex(sel_hi) : -1;

    std::ostringstream out;
    out << "\x1b[?25l";
    out << "\x1b[H";

    const int text_rows = std::max(1, rows - 2);
    for (int y = 0; y < text_rows; ++y) {
      const int file_row = row_offset_ + y;
      out << "\x1b[K";
      if (file_row < static_cast<int>(lines_.size())) {
        const int line_start_index = linearIndex({file_row, 0});
        out << RenderLine(
            lines_[static_cast<size_t>(file_row)],
            col_offset_,
            cols,
            line_start_index,
            selection_start,
            selection_end);
      } else {
        out << '~' << std::string(static_cast<size_t>(std::max(0, cols - 1)), ' ');
      }
      out << "\r\n";
    }

    out << "\x1b[7m";
    std::string status = currentDisplayName();
    if (dirty_) {
      status += " [modified]";
    }
    std::string right = "Ln " + std::to_string(cursor_y_ + 1) + ", Col " + std::to_string(cursor_x_ + 1);
    std::string status_bar(static_cast<size_t>(cols), ' ');
    const int right_start = std::max(0, cols - static_cast<int>(right.size()));
    if (static_cast<int>(status.size()) > right_start) {
      status.resize(static_cast<size_t>(right_start));
    }
    if (!status.empty()) {
      status_bar.replace(0, status.size(), status);
    }
    if (right_start < cols) {
      const size_t count = std::min<size_t>(right.size(), static_cast<size_t>(cols - right_start));
      status_bar.replace(static_cast<size_t>(right_start), count, right.substr(0, count));
    }
    out << status_bar;
    out << "\x1b[m\r\n";

    std::string footer = prompt_message_.empty() ? status_message_ : prompt_message_;
    if (footer.empty()) {
      footer = "Ctrl+E/X/S/D/A/F/R/C/W/Z, K/Q/P prefixes, Ctrl+V paste";
    }
    if (static_cast<int>(footer.size()) > cols) {
      footer.resize(static_cast<size_t>(cols));
    }
    out << "\x1b[K" << footer;
    if (static_cast<int>(footer.size()) < cols) {
      out << std::string(static_cast<size_t>(cols - static_cast<int>(footer.size())), ' ');
    }

    const int cursor_row = (cursor_y_ - row_offset_) + 1;
    const int cursor_col = (RenderX(lines_[static_cast<size_t>(cursor_y_)], cursor_x_) - col_offset_) + 1;
    out << "\x1b[" << cursor_row << ";" << cursor_col << "H";
    out << "\x1b[?25h";

    std::cout << out.str() << std::flush;
  }

  TerminalSize terminalSize() const {
    winsize ws{};
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == -1 || ws.ws_col == 0 || ws.ws_row == 0) {
      return {};
    }
    return {static_cast<int>(ws.ws_row), static_cast<int>(ws.ws_col)};
  }

  void insertChar(char ch) {
    pushUndoSnapshot();
    std::string& line = lines_[static_cast<size_t>(cursor_y_)];
    line.insert(static_cast<size_t>(cursor_x_), 1, ch);
    ++cursor_x_;
    markDirty();
  }

  void insertNewline() {
    pushUndoSnapshot();
    std::string& line = lines_[static_cast<size_t>(cursor_y_)];
    const std::string right = line.substr(static_cast<size_t>(cursor_x_));
    line.erase(static_cast<size_t>(cursor_x_));
    lines_.insert(lines_.begin() + cursor_y_ + 1, right);
    ++cursor_y_;
    cursor_x_ = 0;
    markDirty();
  }

  void backspace() {
    pushUndoSnapshot();
    if (cursor_x_ > 0) {
      std::string& line = lines_[static_cast<size_t>(cursor_y_)];
      line.erase(static_cast<size_t>(cursor_x_ - 1), 1);
      --cursor_x_;
      markDirty();
      return;
    }

    if (cursor_y_ == 0) {
      return;
    }

    const size_t prev_index = static_cast<size_t>(cursor_y_ - 1);
    std::string& prev = lines_[prev_index];
    const std::string current = lines_[static_cast<size_t>(cursor_y_)];
    const int prev_len = static_cast<int>(prev.size());
    prev += current;
    lines_.erase(lines_.begin() + cursor_y_);
    --cursor_y_;
    cursor_x_ = prev_len;
    markDirty();
  }

  void deleteChar() {
    pushUndoSnapshot();
    std::string& line = lines_[static_cast<size_t>(cursor_y_)];
    if (cursor_x_ < static_cast<int>(line.size())) {
      line.erase(static_cast<size_t>(cursor_x_), 1);
      markDirty();
      return;
    }

    if (cursor_y_ + 1 >= static_cast<int>(lines_.size())) {
      return;
    }

    line += lines_[static_cast<size_t>(cursor_y_ + 1)];
    lines_.erase(lines_.begin() + cursor_y_ + 1);
    markDirty();
  }

  void moveLeft() {
    if (cursor_x_ > 0) {
      --cursor_x_;
    } else if (cursor_y_ > 0) {
      --cursor_y_;
      cursor_x_ = static_cast<int>(lines_[static_cast<size_t>(cursor_y_)].size());
    }
    updatePreferredRx();
  }

  void moveRight() {
    const int line_len = static_cast<int>(lines_[static_cast<size_t>(cursor_y_)].size());
    if (cursor_x_ < line_len) {
      ++cursor_x_;
    } else if (cursor_y_ + 1 < static_cast<int>(lines_.size())) {
      ++cursor_y_;
      cursor_x_ = 0;
    }
    updatePreferredRx();
  }

  void moveUp() {
    if (cursor_y_ > 0) {
      --cursor_y_;
      cursor_x_ = CursorXFromRenderX(lines_[static_cast<size_t>(cursor_y_)], preferred_rx_);
    }
  }

  void moveDown() {
    if (cursor_y_ + 1 < static_cast<int>(lines_.size())) {
      ++cursor_y_;
      cursor_x_ = CursorXFromRenderX(lines_[static_cast<size_t>(cursor_y_)], preferred_rx_);
    }
  }

  void moveHome() {
    cursor_x_ = 0;
    updatePreferredRx();
  }

  void moveEnd() {
    cursor_x_ = static_cast<int>(lines_[static_cast<size_t>(cursor_y_)].size());
    updatePreferredRx();
  }

  CursorPos currentPos() const {
    return {cursor_y_, cursor_x_};
  }

  static bool posBefore(const CursorPos& a, const CursorPos& b) {
    if (a.y != b.y) {
      return a.y < b.y;
    }
    return a.x < b.x;
  }

  static std::pair<CursorPos, CursorPos> normalizeRange(CursorPos a, CursorPos b) {
    if (posBefore(b, a)) {
      std::swap(a, b);
    }
    return {a, b};
  }

  int linearIndex(const CursorPos& pos) const {
    int index = 0;
    const int max_y = std::min(pos.y, static_cast<int>(lines_.size()) - 1);
    for (int y = 0; y < max_y; ++y) {
      index += static_cast<int>(lines_[static_cast<size_t>(y)].size()) + 1;
    }
    if (!lines_.empty()) {
      index += std::min(pos.x, static_cast<int>(lines_[static_cast<size_t>(max_y)].size()));
    }
    return index;
  }

  CursorPos posFromLinearIndex(int index) const {
    CursorPos pos{};
    if (index <= 0 || lines_.empty()) {
      return pos;
    }

    int remaining = index;
    for (int y = 0; y < static_cast<int>(lines_.size()); ++y) {
      const int line_len = static_cast<int>(lines_[static_cast<size_t>(y)].size());
      if (remaining <= line_len) {
        pos.y = y;
        pos.x = remaining;
        return pos;
      }
      remaining -= line_len + 1;
    }

    pos.y = static_cast<int>(lines_.size()) - 1;
    pos.x = static_cast<int>(lines_.back().size());
    return pos;
  }

  std::string bufferText() const {
    return JoinLines(lines_);
  }

  void replaceBufferText(const std::string& text) {
    pushUndoSnapshot();
    lines_ = SplitLines(text);
    if (lines_.empty()) {
      lines_.push_back({});
    }
    ensureCursorInRange();
    updatePreferredRx();
    markDirty();
  }

  std::string extractRangeText(CursorPos start, CursorPos end) const {
    const auto [lo, hi] = normalizeRange(start, end);
    const std::string text = bufferText();
    const int start_idx = std::clamp(linearIndex(lo), 0, static_cast<int>(text.size()));
    const int end_idx = std::clamp(linearIndex(hi), 0, static_cast<int>(text.size()));
    if (end_idx <= start_idx) {
      return {};
    }
    return text.substr(static_cast<size_t>(start_idx), static_cast<size_t>(end_idx - start_idx));
  }

  bool findNextText(const std::string& needle, int start_index, bool wrap = true) {
    if (needle.empty()) {
      setStatus("Nothing to find");
      return false;
    }

    const std::string text = bufferText();
    const std::string lowered_text = ToLowerCopy(text);
    const std::string lowered_needle = ToLowerCopy(needle);
    const int clamped_start = std::clamp(start_index, 0, static_cast<int>(text.size()));
    size_t found = lowered_text.find(lowered_needle, static_cast<size_t>(clamped_start));
    bool wrapped = false;
    if (found == std::string::npos && wrap && clamped_start > 0) {
      found = lowered_text.find(lowered_needle, 0);
      wrapped = found != std::string::npos && static_cast<int>(found) < clamped_start;
    }
    if (found == std::string::npos) {
      setStatus("Text not found");
      return false;
    }

    const CursorPos start = posFromLinearIndex(static_cast<int>(found));
    const CursorPos end = posFromLinearIndex(static_cast<int>(found + needle.size()));
    cursor_y_ = start.y;
    cursor_x_ = start.x;
    block_anchor_ = start;
    block_end_ = end;
    ensureCursorInRange();
    updatePreferredRx();
    saveBlockState();
    setStatus(wrapped ? "Text found (wrapped)" : "Text found");
    return true;
  }

  void deleteRange(CursorPos start, CursorPos end) {
    pushUndoSnapshot();
    const auto [lo, hi] = normalizeRange(start, end);
    std::string text = bufferText();
    const int start_idx = std::clamp(linearIndex(lo), 0, static_cast<int>(text.size()));
    const int end_idx = std::clamp(linearIndex(hi), 0, static_cast<int>(text.size()));
    if (end_idx <= start_idx) {
      return;
    }

    text.erase(static_cast<size_t>(start_idx), static_cast<size_t>(end_idx - start_idx));
    lines_ = SplitLines(text);
    if (lines_.empty()) {
      lines_.push_back({});
    }
    const CursorPos cursor = posFromLinearIndex(start_idx);
    cursor_y_ = cursor.y;
    cursor_x_ = cursor.x;
    ensureCursorInRange();
    updatePreferredRx();
    markDirty();
  }

  void insertTextAt(CursorPos pos, const std::string& text) {
    if (text.empty()) {
      return;
    }

    pushUndoSnapshot();
    std::string buffer = bufferText();
    const int insert_idx = std::clamp(linearIndex(pos), 0, static_cast<int>(buffer.size()));
    buffer.insert(static_cast<size_t>(insert_idx), text);
    lines_ = SplitLines(buffer);
    if (lines_.empty()) {
      lines_.push_back({});
    }
    const CursorPos cursor = posFromLinearIndex(insert_idx + static_cast<int>(text.size()));
    cursor_y_ = cursor.y;
    cursor_x_ = cursor.x;
    ensureCursorInRange();
    updatePreferredRx();
    markDirty();
  }

  bool hasBlockRange() const {
    return block_anchor_.has_value() && block_end_.has_value();
  }

  std::pair<CursorPos, CursorPos> blockRange() const {
    if (!hasBlockRange()) {
      return {currentPos(), currentPos()};
    }
    return normalizeRange(*block_anchor_, *block_end_);
  }

  void clearBlockRange() {
    block_anchor_.reset();
    block_end_.reset();
    saveBlockState();
  }

  void beginBlock() {
    pushUndoSnapshot();
    block_anchor_ = currentPos();
    block_end_.reset();
    setStatus("Block begin set");
    saveBlockState();
  }

  void endBlock() {
    if (!block_anchor_.has_value()) {
      setStatus("No block begin set");
      return;
    }
    pushUndoSnapshot();
    block_end_ = currentPos();
    setStatus("Block end set");
    saveBlockState();
  }

  void copySelectionToClipboard(const std::string& text, std::string_view status) {
    if (text.empty()) {
      setStatus("Nothing to copy");
      return;
    }

    clipboard_cache_ = text;
    saveClipboardCache(clipboard_cache_);

    const bool copied = SystemClipboardCopy(text);
    if (copied) {
      setStatus(std::string(status) + " to clipboard");
    } else {
      setStatus(std::string(status) + " to clipboard cache");
    }
  }

  void copyBlock() {
    if (!hasBlockRange()) {
      setStatus("No block selected");
      return;
    }
    const auto [lo, hi] = blockRange();
    copySelectionToClipboard(extractRangeText(lo, hi), "Block copied");
  }

  void cutBlock() {
    if (!hasBlockRange()) {
      setStatus("No block selected");
      return;
    }
    const auto [lo, hi] = blockRange();
    const std::string text = extractRangeText(lo, hi);
    copySelectionToClipboard(text, "Block cut");
    deleteRange(lo, hi);
    clearBlockRange();
  }

  void moveBlock() {
    if (!hasBlockRange()) {
      setStatus("No block selected");
      return;
    }
    const CursorPos destination = currentPos();
    const auto [lo, hi] = blockRange();
    const int source_start = linearIndex(lo);
    const int source_end = linearIndex(hi);
    int destination_index = linearIndex(destination);
    const std::string text = extractRangeText(lo, hi);
    deleteRange(lo, hi);
    if (destination_index > source_end) {
      destination_index -= (source_end - source_start);
    } else if (destination_index > source_start) {
      destination_index = source_start;
    }
    insertTextAt(posFromLinearIndex(destination_index), text);
    clearBlockRange();
    setStatus("Block moved");
  }

  void deleteBlock() {
    if (!hasBlockRange()) {
      setStatus("No block selected");
      return;
    }
    const auto [lo, hi] = blockRange();
    deleteRange(lo, hi);
    clearBlockRange();
    setStatus("Block deleted");
  }

  void pasteClipboard() {
    pushUndoSnapshot();
    std::string text = clipboard_cache_;
    if (text.empty()) {
      auto pasted = SystemClipboardPaste();
      if (pasted.has_value()) {
        text = *pasted;
        saveClipboardCache(text);
      } else {
        const auto cached = ReadAllText(ClipboardCachePath());
        if (cached.has_value()) {
          text = *cached;
          clipboard_cache_ = text;
        }
      }
    }

    if (text.empty()) {
      setStatus("Clipboard empty");
      return;
    }

    insertTextAt(currentPos(), text);
    setStatus("Pasted clipboard");
  }

  void toggleMarker(const std::string& marker, bool& active, std::string_view label) {
    insertTextAt(currentPos(), marker);
    active = !active;
    setStatus(std::string(label) + (active ? " on" : " off"));
  }

  void saveAndExit() {
    if (saveCurrentFile(false)) {
      quit_ = true;
    }
  }

  void exitWithoutSaving() {
    quit_ = true;
  }

  void deleteToEndOfLine() {
    pushUndoSnapshot();
    std::string& line = lines_[static_cast<size_t>(cursor_y_)];
    if (cursor_x_ < static_cast<int>(line.size())) {
      line.erase(static_cast<size_t>(cursor_x_));
      markDirty();
      setStatus("Deleted to end of line");
    } else {
      setStatus("Nothing to delete");
    }
  }

  void moveToDocumentEnd() {
    cursor_y_ = static_cast<int>(lines_.size()) - 1;
    cursor_x_ = static_cast<int>(lines_.back().size());
    updatePreferredRx();
    setStatus("Moved to end of document");
  }

  void moveToLineStart() {
    moveHome();
    setStatus("Moved to beginning of line");
  }

  void moveToLineEnd() {
    moveEnd();
    setStatus("Moved to end of line");
  }

  void deleteLine() {
    pushUndoSnapshot();
    if (lines_.size() <= 1) {
      lines_[0].clear();
      cursor_x_ = 0;
      cursor_y_ = 0;
      markDirty();
      setStatus("Line deleted");
      return;
    }

    lines_.erase(lines_.begin() + cursor_y_);
    if (cursor_y_ >= static_cast<int>(lines_.size())) {
      cursor_y_ = static_cast<int>(lines_.size()) - 1;
    }
    ensureCursorInRange();
    updatePreferredRx();
    markDirty();
    setStatus("Line deleted");
  }

  void deleteWordRight() {
    pushUndoSnapshot();
    const std::string text = bufferText();
    const int start_idx = std::clamp(linearIndex(currentPos()), 0, static_cast<int>(text.size()));
    int end_idx = start_idx;
    while (end_idx < static_cast<int>(text.size()) &&
           std::isspace(static_cast<unsigned char>(text[static_cast<size_t>(end_idx)]))) {
      ++end_idx;
    }
    while (end_idx < static_cast<int>(text.size()) &&
           text[static_cast<size_t>(end_idx)] != '\n' &&
           !std::isspace(static_cast<unsigned char>(text[static_cast<size_t>(end_idx)]))) {
      ++end_idx;
    }
    if (end_idx <= start_idx) {
      setStatus("Nothing to delete");
      return;
    }

    std::string buffer = text;
    buffer.erase(static_cast<size_t>(start_idx), static_cast<size_t>(end_idx - start_idx));
    lines_ = SplitLines(buffer);
    if (lines_.empty()) {
      lines_.push_back({});
    }
    const CursorPos cursor = posFromLinearIndex(start_idx);
    cursor_y_ = cursor.y;
    cursor_x_ = cursor.x;
    ensureCursorInRange();
    updatePreferredRx();
    markDirty();
    setStatus("Word deleted");
  }

  void reformatParagraph() {
    if (lines_.empty()) {
      return;
    }

    pushUndoSnapshot();
    int start = cursor_y_;
    while (start > 0 && !lines_[static_cast<size_t>(start - 1)].empty()) {
      --start;
    }

    int end = cursor_y_;
    while (end + 1 < static_cast<int>(lines_.size()) &&
           !lines_[static_cast<size_t>(end + 1)].empty()) {
      ++end;
    }

    std::vector<std::string> words;
    for (int y = start; y <= end; ++y) {
      std::istringstream iss(lines_[static_cast<size_t>(y)]);
      std::string word;
      while (iss >> word) {
        words.push_back(word);
      }
    }

    if (words.empty()) {
      return;
    }

    constexpr int kParagraphWidth = 1000;
    std::vector<std::string> wrapped;
    std::string line;
    for (const auto& word : words) {
      if (line.empty()) {
        line = word;
        continue;
      }
      if (static_cast<int>(line.size()) + 1 + static_cast<int>(word.size()) > kParagraphWidth) {
        wrapped.push_back(line);
        line = word;
      } else {
        line.push_back(' ');
        line += word;
      }
    }
    if (!line.empty()) {
      wrapped.push_back(line);
    }

    lines_.erase(lines_.begin() + start, lines_.begin() + end + 1);
    lines_.insert(lines_.begin() + start, wrapped.begin(), wrapped.end());
    cursor_y_ = start;
    cursor_x_ = 0;
    ensureCursorInRange();
    updatePreferredRx();
    markDirty();
    setStatus("Paragraph reformatted");
  }

  static bool isWordChar(unsigned char ch) {
    return std::isalnum(ch) != 0 || ch == '_';
  }

  void moveWordLeft() {
    if (cursor_x_ == 0 && cursor_y_ == 0) {
      return;
    }

    if (cursor_x_ == 0 && cursor_y_ > 0) {
      --cursor_y_;
      const std::string& prev_line = lines_[static_cast<size_t>(cursor_y_)];
      int x = static_cast<int>(prev_line.size());
      while (x > 0 && std::isspace(static_cast<unsigned char>(prev_line[static_cast<size_t>(x - 1)]))) {
        --x;
      }
      while (x > 0 && isWordChar(static_cast<unsigned char>(prev_line[static_cast<size_t>(x - 1)]))) {
        --x;
      }
      cursor_x_ = x;
      ensureCursorInRange();
      updatePreferredRx();
      return;
    }

    auto stepLeft = [&]() {
      if (cursor_x_ > 0) {
        --cursor_x_;
      } else if (cursor_y_ > 0) {
        --cursor_y_;
        cursor_x_ = static_cast<int>(lines_[static_cast<size_t>(cursor_y_)].size());
      }
    };

    while (cursor_x_ > 0 || cursor_y_ > 0) {
      const std::string& line = lines_[static_cast<size_t>(cursor_y_)];
      if (cursor_x_ == 0) {
        break;
      }

      const unsigned char prev = static_cast<unsigned char>(line[static_cast<size_t>(cursor_x_ - 1)]);
      if (!std::isspace(prev)) {
        break;
      }
      stepLeft();
    }

    while (cursor_x_ > 0 || cursor_y_ > 0) {
      const std::string& line = lines_[static_cast<size_t>(cursor_y_)];
      if (cursor_x_ == 0) {
        break;
      }

      const unsigned char prev = static_cast<unsigned char>(line[static_cast<size_t>(cursor_x_ - 1)]);
      if (!isWordChar(prev)) {
        break;
      }
      stepLeft();
    }

    ensureCursorInRange();
    updatePreferredRx();
  }

  void moveWordRight() {
    const std::string& line = lines_[static_cast<size_t>(cursor_y_)];
    const int line_len = static_cast<int>(line.size());
    if (cursor_x_ >= line_len) {
      if (cursor_y_ + 1 < static_cast<int>(lines_.size())) {
        ++cursor_y_;
        const std::string& next_line = lines_[static_cast<size_t>(cursor_y_)];
        int x = 0;
        while (x < static_cast<int>(next_line.size()) &&
               std::isspace(static_cast<unsigned char>(next_line[static_cast<size_t>(x)]))) {
          ++x;
        }
        cursor_x_ = x;
      }
      updatePreferredRx();
      return;
    }

    auto isWordAt = [&](int index) {
      return index >= 0 && index < line_len &&
             isWordChar(static_cast<unsigned char>(line[static_cast<size_t>(index)]));
    };

    int x = cursor_x_;
    if (isWordAt(x)) {
      while (x < line_len && isWordChar(static_cast<unsigned char>(line[static_cast<size_t>(x)]))) {
        ++x;
      }
    }

    while (x < line_len && !isWordChar(static_cast<unsigned char>(line[static_cast<size_t>(x)]))) {
      ++x;
    }

    if (x >= line_len) {
      cursor_x_ = line_len;
    } else {
      cursor_x_ = x;
    }

    ensureCursorInRange();
    updatePreferredRx();
  }

  void scrollUpOneLine() {
    if (row_offset_ > 0) {
      --row_offset_;
    }
  }

  void scrollDownOneLine() {
    const TerminalSize size = terminalSize();
    const int text_rows = std::max(1, size.rows - 2);
    const int max_offset = std::max(0, static_cast<int>(lines_.size()) - text_rows);
    if (row_offset_ < max_offset) {
      ++row_offset_;
    }
  }

  bool confirm(std::string_view question) {
    const auto answer = prompt(std::string(question) + " [y/n] ");
    if (!answer.has_value()) {
      return false;
    }
    const std::string trimmed = TrimTrailingCarriageReturns(*answer);
    return !trimmed.empty() && (trimmed[0] == 'y' || trimmed[0] == 'Y');
  }

  std::optional<std::string> prompt(const std::string& question, const std::string& initial = {}) {
    std::string input = initial;
    setPrompt(question + input);
    refreshScreen();

    while (true) {
      Key key = readKey();
      switch (key.type) {
        case KeyType::Enter:
          setPrompt({});
          return input;
        case KeyType::Escape:
          setPrompt({});
          return std::nullopt;
        case KeyType::Backspace:
          if (!input.empty()) {
            input.pop_back();
          }
          break;
        case KeyType::Char:
          if (std::isprint(static_cast<unsigned char>(key.ch))) {
            input.push_back(key.ch);
          }
          break;
        default:
          break;
      }
      setPrompt(question + input);
      refreshScreen();
    }
  }

  bool saveCurrentFile(bool prompt_for_name) {
    if (file_path_.empty() || prompt_for_name) {
      const auto path = prompt("Save as: ", file_path_.empty() ? std::string{} : file_path_.string());
      if (!path.has_value() || path->empty()) {
        setStatus("Save canceled");
        return false;
      }
      file_path_ = *path;
    }

    const std::string text = JoinLines(lines_);
    if (!WriteAll(file_path_, text)) {
      setStatus("Save failed: " + std::string(std::strerror(errno)));
      return false;
    }

    dirty_ = false;
    setStatus("Saved " + file_path_.string());
    saveBlockState();
    return true;
  }

  bool loadFile(const std::filesystem::path& path) {
    pushUndoSnapshot();
    std::string raw = ReadAll(path);
    if (raw.empty() && !std::filesystem::exists(path)) {
      setStatus("Open failed: file not found");
      return false;
    }

    if (raw.size() >= 3 &&
        static_cast<unsigned char>(raw[0]) == 0xEF &&
        static_cast<unsigned char>(raw[1]) == 0xBB &&
        static_cast<unsigned char>(raw[2]) == 0xBF) {
      raw.erase(0, 3);
    }

    std::string text = NormalizeNewlines(raw);

    lines_ = SplitLines(text);
    if (lines_.empty()) {
      lines_.push_back({});
    }

    file_path_ = path;
    cursor_x_ = 0;
    cursor_y_ = 0;
    row_offset_ = 0;
    col_offset_ = 0;
    preferred_rx_ = 0;
    dirty_ = false;
    restoreBlockStateForCurrentFile();
    setStatus("Opened " + file_path_.string());
    return true;
  }

  void newFile() {
    pushUndoSnapshot();
    lines_.assign(1, std::string{});
    file_path_.clear();
    cursor_x_ = 0;
    cursor_y_ = 0;
    row_offset_ = 0;
    col_offset_ = 0;
    preferred_rx_ = 0;
    dirty_ = false;
    clearBlockRange();
    setStatus("New buffer");
  }

  void openInteractive() {
    if (dirty_) {
      if (confirm("Save current file before opening another?")) {
        if (!saveCurrentFile(false)) {
          return;
        }
      }
    }

    const auto path = prompt("Open: ", file_path_.empty() ? std::string{} : file_path_.string());
    if (!path.has_value() || path->empty()) {
      setStatus("Open canceled");
      return;
    }

    if (!loadFile(*path)) {
      setStatus("Open failed");
    }
  }

  void handleQuit() {
    if (dirty_) {
      const auto answer = prompt("Unsaved changes. Save before quit? [y]es/[n]o/[c]ancel ");
      if (!answer.has_value() || answer->empty()) {
        return;
      }
      const char choice = static_cast<char>(std::tolower(static_cast<unsigned char>((*answer)[0])));
      if (choice == 'c') {
        return;
      }
      if (choice == 'y' && !saveCurrentFile(false)) {
        return;
      }
    }
    quit_ = true;
  }

  void handleKPrefix(char ch) {
    switch (std::tolower(static_cast<unsigned char>(ch))) {
      case 'n':
        if (!dirty_ || confirm("Save current file before new buffer?")) {
          if (!dirty_ || saveCurrentFile(false)) {
            newFile();
          }
        }
        break;
      case 'o':
        openInteractive();
        break;
      case 's':
        saveCurrentFile(false);
        break;
      case 'd':
      case 'x':
        saveAndExit();
        break;
      case 'q':
        exitWithoutSaving();
        break;
      case 'b':
        beginBlock();
        break;
      case 'k':
        endBlock();
        break;
      case 'c':
        copyBlock();
        break;
      case 'v':
        moveBlock();
        break;
      case 'y':
        cutBlock();
        break;
      case 'a':
        moveToLineStart();
        break;
      case 'f':
        moveToLineEnd();
        break;
      default:
        setStatus(std::string("Ctrl+K command not mapped: ") + ch);
        break;
    }
  }

  void handleQPrefix(char ch) {
    switch (std::tolower(static_cast<unsigned char>(ch))) {
      case 'r':
        cursor_y_ = 0;
        cursor_x_ = 0;
        updatePreferredRx();
        setStatus("Moved to beginning of document");
        break;
      case 'c':
        moveToDocumentEnd();
        break;
      case 'v':
        moveToDocumentEnd();
        break;
      case 'f': {
        std::string needle;
        int search_start = linearIndex(currentPos()) + 1;
        if (hasBlockRange()) {
          const auto [lo, hi] = blockRange();
          needle = extractRangeText(lo, hi);
          search_start = linearIndex(hi);
        } else {
          const auto query = prompt("Find: ");
          if (!query.has_value() || query->empty()) {
            setStatus("Find canceled");
            return;
          }
          needle = *query;
        }
        last_find_query_ = needle;
        findNextText(needle, search_start);
        break;
      }
      case 'y':
        deleteToEndOfLine();
        break;
      default:
        setStatus(std::string("Ctrl+Q command not mapped: ") + ch);
        break;
    }
  }

  void handlePPrefix(char ch) {
    switch (std::tolower(static_cast<unsigned char>(ch))) {
      case 'b':
        toggleMarker("**", bold_active_, "Bold");
        break;
      case 's':
        toggleMarker("__", underline_active_, "Underline");
        break;
      default:
        setStatus(std::string("Ctrl+P command not mapped: ") + ch);
        break;
    }
  }

  static std::optional<char> normalizePrefixKey(const Key& key) {
    if (key.type == KeyType::Char) {
      return static_cast<char>(std::tolower(static_cast<unsigned char>(key.ch)));
    }
    if (key.type == KeyType::CtrlKey && key.ch >= 1 && key.ch <= 26) {
      return static_cast<char>('a' + (key.ch - 1));
    }
    return std::nullopt;
  }

  void handleKey(const Key& key) {
    if (prefix_mode_ != PrefixMode::None) {
      const PrefixMode prefix = prefix_mode_;
      prefix_mode_ = PrefixMode::None;
      const auto normalized = normalizePrefixKey(key);
      if (!normalized.has_value()) {
        setStatus("Prefix canceled");
        return;
      }

      switch (prefix) {
        case PrefixMode::K:
          handleKPrefix(*normalized);
          break;
        case PrefixMode::Q:
          handleQPrefix(*normalized);
          break;
        case PrefixMode::P:
          handlePPrefix(*normalized);
          break;
        case PrefixMode::None:
          break;
      }
      return;
    }

    switch (key.type) {
      case KeyType::CtrlKey:
        switch (key.ch) {
          case 1:
            moveWordLeft();
            break;
          case 2:
            reformatParagraph();
            break;
          case 3:
            for (int i = 0; i < 10; ++i) {
              moveDown();
            }
            break;
          case 4:
            moveRight();
            break;
          case 5:
            moveUp();
            break;
          case 6:
            moveWordRight();
            break;
          case 7:
            deleteChar();
            break;
          case 8:
            backspace();
            break;
          case 11:
            prefix_mode_ = PrefixMode::K;
            setStatus("Ctrl+K prefix");
            break;
          case 12:
            if (last_find_query_.empty()) {
              setStatus("No previous find");
              break;
            }
            findNextText(
                last_find_query_,
                hasBlockRange() ? linearIndex(blockRange().second) : linearIndex(currentPos()) + 1);
            break;
          case 13:
            insertNewline();
            break;
          case 15:
            openInteractive();
            break;
          case 16:
            prefix_mode_ = PrefixMode::P;
            setStatus("Ctrl+P prefix");
            break;
          case 17:
            prefix_mode_ = PrefixMode::Q;
            setStatus("Ctrl+Q prefix");
            break;
          case 18:
            for (int i = 0; i < 10; ++i) {
              moveUp();
            }
            break;
          case 19:
            moveLeft();
            break;
          case 20:
            deleteWordRight();
            break;
          case 22:
            pasteClipboard();
            break;
          case 23:
            scrollUpOneLine();
            break;
          case 24:
            moveDown();
            break;
          case 25:
            deleteLine();
            break;
          case 26:
            scrollDownOneLine();
            break;
          default:
            break;
        }
        break;
      case KeyType::Undo:
        undoLastAction();
        break;
      case KeyType::Char:
        if (std::isprint(static_cast<unsigned char>(key.ch))) {
          insertChar(key.ch);
          updatePreferredRx();
        }
        break;
      case KeyType::Enter:
        insertNewline();
        updatePreferredRx();
        break;
      case KeyType::Backspace:
        backspace();
        updatePreferredRx();
        break;
      case KeyType::Delete:
        deleteChar();
        updatePreferredRx();
        break;
      case KeyType::ArrowLeft:
        moveLeft();
        break;
      case KeyType::ArrowRight:
        moveRight();
        break;
      case KeyType::ArrowUp:
        moveUp();
        break;
      case KeyType::ArrowDown:
        moveDown();
        break;
      case KeyType::Home:
        moveHome();
        break;
      case KeyType::End:
        moveEnd();
        break;
      case KeyType::PageUp:
        for (int i = 0; i < 10; ++i) {
          moveUp();
        }
        break;
      case KeyType::PageDown:
        for (int i = 0; i < 10; ++i) {
          moveDown();
        }
        break;
      case KeyType::Escape:
        setStatus("Esc");
        break;
      default:
        break;
    }
    ensureCursorInRange();
    updatePreferredRx();
  }

  Key readKey() {
    while (true) {
      char c = '\0';
      const ssize_t n = ::read(STDIN_FILENO, &c, 1);
      if (n == 0) {
        continue;
      }
      if (n == -1) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
          continue;
        }
        return {};
      }

      if (c == '\x1b') {
        return readEscapeSequence();
      }

      if (c == '\r' || c == '\n') {
        return {KeyType::Enter, '\n'};
      }

      if (c == 127 || c == '\b') {
        return {KeyType::Backspace, c};
      }

      if (static_cast<unsigned char>(c) < 32) {
        return {KeyType::CtrlKey, c};
      }

      return {KeyType::Char, c};
    }
  }

  Key readEscapeSequence() {
    char seq[3] = {0, 0, 0};
    const ssize_t n1 = ::read(STDIN_FILENO, &seq[0], 1);
    if (n1 != 1) {
      return {KeyType::Escape, '\x1b'};
    }

    if (seq[0] == 127 || seq[0] == '\b') {
      return {KeyType::Undo, '\0'};
    }

    if (seq[0] != '[') {
      return {KeyType::Escape, '\x1b'};
    }

    const ssize_t n2 = ::read(STDIN_FILENO, &seq[1], 1);
    if (n2 != 1) {
      return {KeyType::Escape, '\x1b'};
    }

    if (seq[1] >= '0' && seq[1] <= '9') {
      const ssize_t n3 = ::read(STDIN_FILENO, &seq[2], 1);
      if (n3 != 1) {
        return {KeyType::Escape, '\x1b'};
      }
      switch (seq[1]) {
        case '1':
          if (seq[2] == '~') return {KeyType::Home, '\0'};
          break;
        case '3':
          if (seq[2] == '~') return {KeyType::Delete, '\0'};
          break;
        case '4':
          if (seq[2] == '~') return {KeyType::End, '\0'};
          break;
        case '5':
          if (seq[2] == '~') return {KeyType::PageUp, '\0'};
          break;
        case '6':
          if (seq[2] == '~') return {KeyType::PageDown, '\0'};
          break;
        case '7':
          if (seq[2] == '~') return {KeyType::Home, '\0'};
          break;
        case '8':
          if (seq[2] == '~') return {KeyType::End, '\0'};
          break;
        default:
          break;
      }
      return {KeyType::Unknown, '\0'};
    }

    switch (seq[1]) {
      case 'A':
        return {KeyType::ArrowUp, '\0'};
      case 'B':
        return {KeyType::ArrowDown, '\0'};
      case 'C':
        return {KeyType::ArrowRight, '\0'};
      case 'D':
        return {KeyType::ArrowLeft, '\0'};
      case 'H':
        return {KeyType::Home, '\0'};
      case 'F':
        return {KeyType::End, '\0'};
      default:
        return {KeyType::Unknown, '\0'};
    }
  }
};

}  // namespace

int main(int argc, char* argv[]) {
  std::filesystem::path open_path;
  if (argc > 2) {
    std::cerr << "Usage: WSEditor [file]\n";
    return 1;
  }
  if (argc == 2) {
    open_path = argv[1];
  }

  RawTerminal terminal;
  if (!terminal.active()) {
    std::cerr << "WSEditor requires an interactive terminal.\n";
    return 1;
  }

  std::cout << "\x1b[2J\x1b[H" << std::flush;
  Editor editor(std::move(open_path));
  editor.run();

  std::cout << "\x1b[2J\x1b[H" << std::flush;
  return 0;
}
