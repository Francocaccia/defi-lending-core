#include "json.hpp"
#include "simtest.hpp"

using sim::Json;
using sim::JsonError;
using sim::parseJson;

TEST(json_parses_scalars_and_containers) {
  const Json j = parseJson(R"({"a": 1, "b": "x\ty", "c": [1, 2.5, "z"], "d": {"e": true, "f": null}, "g": false})");
  CHECK(j.isObject());
  CHECK_EQ(j.at("a").str(), std::string("1"));
  CHECK_EQ(j.at("b").str(), std::string("x\ty"));
  CHECK_EQ(j.at("c").items.size(), static_cast<std::size_t>(3));
  CHECK_EQ(j.at("c").items[1].str(), std::string("2.5"));
  CHECK(j.at("d").at("e").boolean);
  CHECK(j.at("d").at("f").isNull());
  CHECK(!j.at("g").boolean);
}

TEST(json_keeps_long_integers_as_exact_text) {
  // 18-digit WAD values must never pass through a double.
  const Json j = parseJson(R"({"maxLtv": 750000000000000000, "x": 115792089237316195423570985008687907853269984665640564039457584007913129639935})");
  CHECK_EQ(j.at("maxLtv").str(), std::string("750000000000000000"));
  CHECK_EQ(j.at("x").str().size(), static_cast<std::size_t>(78));
}

TEST(json_unicode_escape_and_nesting) {
  // Escapes written with doubled backslashes so the JSON parser (not the C++ compiler) decodes them.
  const Json j = parseJson("[\"\\u0041\\u00e9\", [[[]]], {}]");
  CHECK_EQ(j.items[0].str(), std::string("A\xC3\xA9"));
  CHECK(j.items[1].items[0].items[0].isArray());
  CHECK(j.items[2].isObject());
}

TEST(json_rejects_malformed_documents) {
  CHECK_THROWS_ANY(parseJson("{"));
  CHECK_THROWS_ANY(parseJson("[1,]"));
  CHECK_THROWS_ANY(parseJson(R"({"a" 1})"));
  CHECK_THROWS_ANY(parseJson(R"({"a": 1} extra)"));
  CHECK_THROWS_ANY(parseJson(R"("unterminated)"));
  CHECK_THROWS_ANY(parseJson("nope"));
  CHECK_THROWS_ANY(parseJson(""));
}

TEST(json_accessors_report_the_missing_key) {
  const Json j = parseJson(R"({"a": 1})");
  CHECK(j.find("zzz") == nullptr);
  try {
    (void)j.at("zzz");
    CHECK(false);
  } catch (const JsonError& e) {
    CHECK(std::string(e.what()).find("zzz") != std::string::npos);
  }
}

TEST(json_strList_accepts_scalar_or_array) {
  const Json j = parseJson(R"({"one": "0.5", "many": ["0.1", 2, "0.3"]})");
  CHECK_EQ(j.at("one").strList().size(), static_cast<std::size_t>(1));
  CHECK_EQ(j.at("many").strList().size(), static_cast<std::size_t>(3));
  CHECK_EQ(j.at("many").strList()[1], std::string("2"));
}
