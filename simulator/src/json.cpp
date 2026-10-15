#include "json.hpp"

#include <cctype>
#include <cstdint>

namespace sim {

const Json* Json::find(const std::string& key) const {
  for (const auto& f : fields) {
    if (f.first == key) return &f.second;
  }
  return nullptr;
}

const Json& Json::at(const std::string& key) const {
  if (type != Type::Object) throw JsonError("expected an object while looking for '" + key + "'");
  const Json* v = find(key);
  if (v == nullptr) throw JsonError("missing required key '" + key + "'");
  return *v;
}

const std::string& Json::str() const {
  if (type != Type::String && type != Type::Number) throw JsonError("expected a string or number");
  return text;
}

std::vector<std::string> Json::strList() const {
  std::vector<std::string> out;
  if (type == Type::Array) {
    for (const Json& it : items) out.push_back(it.str());
  } else {
    out.push_back(str());
  }
  return out;
}

namespace {

class Parser {
 public:
  explicit Parser(const std::string& s) : s_(s) {}

  Json document() {
    Json v = value();
    skipWs();
    if (i_ != s_.size()) fail("unexpected trailing characters");
    return v;
  }

 private:
  const std::string& s_;
  std::size_t i_ = 0;

  [[noreturn]] void fail(const std::string& msg) const {
    throw JsonError("JSON error at offset " + std::to_string(i_) + ": " + msg);
  }

  void skipWs() {
    while (i_ < s_.size() && std::isspace(static_cast<unsigned char>(s_[i_])) != 0) ++i_;
  }

  char peek() {
    skipWs();
    if (i_ >= s_.size()) fail("unexpected end of input");
    return s_[i_];
  }

  void expect(char c) {
    if (peek() != c) fail(std::string("expected '") + c + "'");
    ++i_;
  }

  bool consumeWord(const char* w) {
    std::size_t n = 0;
    while (w[n] != '\0') ++n;
    if (s_.compare(i_, n, w) == 0) {
      i_ += n;
      return true;
    }
    return false;
  }

  Json value() {
    const char c = peek();
    if (c == '{') return object();
    if (c == '[') return array();
    if (c == '"') {
      Json j;
      j.type = Json::Type::String;
      j.text = string();
      return j;
    }
    if (c == '-' || (c >= '0' && c <= '9')) return number();
    Json j;
    if (consumeWord("true")) {
      j.type = Json::Type::Bool;
      j.boolean = true;
      return j;
    }
    if (consumeWord("false")) {
      j.type = Json::Type::Bool;
      return j;
    }
    if (consumeWord("null")) return j;
    fail("unexpected character");
  }

  Json number() {
    const std::size_t start = i_;
    if (s_[i_] == '-') ++i_;
    while (i_ < s_.size() &&
           (std::isdigit(static_cast<unsigned char>(s_[i_])) != 0 || s_[i_] == '.' ||
            s_[i_] == 'e' || s_[i_] == 'E' || s_[i_] == '+' || s_[i_] == '-')) {
      ++i_;
    }
    Json j;
    j.type = Json::Type::Number;
    j.text = s_.substr(start, i_ - start);
    return j;
  }

  std::string string() {
    expect('"');
    std::string out;
    while (true) {
      if (i_ >= s_.size()) fail("unterminated string");
      const char c = s_[i_++];
      if (c == '"') break;
      if (c != '\\') {
        out.push_back(c);
        continue;
      }
      if (i_ >= s_.size()) fail("unterminated escape");
      const char e = s_[i_++];
      switch (e) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'n': out.push_back('\n'); break;
        case 't': out.push_back('\t'); break;
        case 'r': out.push_back('\r'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'u': {
          // Only the BMP, encoded as UTF-8 (labels are ASCII in practice).
          if (i_ + 4 > s_.size()) fail("short \\u escape");
          unsigned cp = 0;
          for (int k = 0; k < 4; ++k) {
            const char h = s_[i_++];
            cp <<= 4U;
            if (h >= '0' && h <= '9') cp |= static_cast<unsigned>(h - '0');
            else if (h >= 'a' && h <= 'f') cp |= static_cast<unsigned>(h - 'a' + 10);
            else if (h >= 'A' && h <= 'F') cp |= static_cast<unsigned>(h - 'A' + 10);
            else fail("bad hex digit in \\u escape");
          }
          if (cp < 0x80U) {
            out.push_back(static_cast<char>(cp));
          } else if (cp < 0x800U) {
            out.push_back(static_cast<char>(0xC0U | (cp >> 6U)));
            out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
          } else {
            out.push_back(static_cast<char>(0xE0U | (cp >> 12U)));
            out.push_back(static_cast<char>(0x80U | ((cp >> 6U) & 0x3FU)));
            out.push_back(static_cast<char>(0x80U | (cp & 0x3FU)));
          }
          break;
        }
        default: fail("unknown escape");
      }
    }
    return out;
  }

  Json array() {
    expect('[');
    Json j;
    j.type = Json::Type::Array;
    if (peek() == ']') {
      ++i_;
      return j;
    }
    while (true) {
      j.items.push_back(value());
      const char c = peek();
      ++i_;
      if (c == ']') break;
      if (c != ',') fail("expected ',' or ']'");
    }
    return j;
  }

  Json object() {
    expect('{');
    Json j;
    j.type = Json::Type::Object;
    if (peek() == '}') {
      ++i_;
      return j;
    }
    while (true) {
      if (peek() != '"') fail("expected a string key");
      std::string key = string();
      expect(':');
      j.fields.emplace_back(std::move(key), value());
      const char c = peek();
      ++i_;
      if (c == '}') break;
      if (c != ',') fail("expected ',' or '}'");
    }
    return j;
  }
};

}  // namespace

Json parseJson(const std::string& document) { return Parser(document).document(); }

}  // namespace sim
