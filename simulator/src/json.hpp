// A deliberately small JSON reader (objects, arrays, strings, numbers, true/false/null).
// Numbers are kept as their original TEXT so that on-chain style integers (WAD values with 18
// digits) are never rounded through a double. No third-party dependency.
#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace sim {

class JsonError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

class Json {
 public:
  enum class Type { Null, Bool, Number, String, Array, Object };

  Type type = Type::Null;
  bool boolean = false;
  std::string text;  // Number: raw token text; String: decoded contents
  std::vector<Json> items;                           // Array
  std::vector<std::pair<std::string, Json>> fields;  // Object (insertion order)

  bool isNull() const { return type == Type::Null; }
  bool isArray() const { return type == Type::Array; }
  bool isObject() const { return type == Type::Object; }
  bool isString() const { return type == Type::String; }
  bool isNumber() const { return type == Type::Number; }

  /// Object member or nullptr.
  const Json* find(const std::string& key) const;
  /// Object member; throws JsonError if absent (message names the key).
  const Json& at(const std::string& key) const;
  /// Text of a String or Number value; throws otherwise.
  const std::string& str() const;
  /// Convenience: value as a list of texts (a scalar becomes a one-element list).
  std::vector<std::string> strList() const;
};

/// Parses a complete document; trailing garbage is an error.
Json parseJson(const std::string& document);

}  // namespace sim
