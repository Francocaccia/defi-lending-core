#include "config.hpp"

#include <fstream>
#include <sstream>
#include <stdexcept>

#include "model.hpp"
#include "units.hpp"

namespace sim {

namespace {

std::string readFile(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error("cannot open '" + path + "'");
  std::ostringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

std::string dirOf(const std::string& path) {
  const std::size_t slash = path.find_last_of("/\\");
  return slash == std::string::npos ? std::string(".") : path.substr(0, slash);
}

bool isAbsolute(const std::string& p) {
  return !p.empty() && (p[0] == '/' || p[0] == '\\' || (p.size() > 1 && p[1] == ':'));
}

std::string resolve(const std::string& baseDir, const std::string& p) {
  return isAbsolute(p) ? p : baseDir + "/" + p;
}

int toInt(const std::string& s, const char* what) {
  try {
    std::size_t used = 0;
    const int v = std::stoi(s, &used);
    if (used != s.size()) throw std::invalid_argument("trailing characters");
    return v;
  } catch (const std::exception&) {
    throw std::runtime_error(std::string("config: '") + what + "' must be an integer, got '" + s + "'");
  }
}

double toDoubleText(const std::string& s, const char* what) {
  try {
    std::size_t used = 0;
    const double v = std::stod(s, &used);
    if (used != s.size()) throw std::invalid_argument("trailing characters");
    return v;
  } catch (const std::exception&) {
    throw std::runtime_error(std::string("config: '") + what + "' must be a number, got '" + s + "'");
  }
}

void readRate(const Json& rate, ProtocolParams& p) {
  p.baseRate = parseWadParam(rate.at("baseRate").str());
  p.slope1 = parseWadParam(rate.at("slope1").str());
  p.slope2 = parseWadParam(rate.at("slope2").str());
  p.optimalUtilization = parseWadParam(rate.at("optimalUtilization").str());
}

}  // namespace

ProtocolParams parseProtocol(const Json& obj, const ProtocolParams* defaultRate) {
  ProtocolParams p;
  p.maxLtv = parseWadParam(obj.at("maxLtv").str());
  p.liquidationThreshold = parseWadParam(obj.at("liquidationThreshold").str());
  p.liquidationBonus = parseWadParam(obj.at("liquidationBonus").str());
  p.closeFactor = parseWadParam(obj.at("closeFactor").str());
  if (const Json* rate = obj.find("rate")) {
    readRate(*rate, p);
  } else if (defaultRate != nullptr) {
    p.baseRate = defaultRate->baseRate;
    p.slope1 = defaultRate->slope1;
    p.slope2 = defaultRate->slope2;
    p.optimalUtilization = defaultRate->optimalUtilization;
  } else {
    throw JsonError("protocol object needs a 'rate' object (or a top-level defaultRate)");
  }
  return p;
}

Config parseConfig(const Json& root, const std::string& baseDir) {
  Config c;
  c.name = root.at("name").str();
  if (const Json* d = root.find("description")) c.description = d->str();

  const Json& data = root.at("data");
  c.ethCsv = resolve(baseDir, data.at("eth").str());
  c.usdcCsv = resolve(baseDir, data.at("usdc").str());

  if (const Json* s = root.find("stepSeconds")) c.stepSeconds = toInt(s->str(), "stepSeconds");
  if (c.stepSeconds <= 0) throw std::runtime_error("config: stepSeconds must be positive");

  const Json& src = root.at("source");
  const std::string type = src.at("type").str();
  if (type == "historical") {
    c.source.kind = SourceSpec::Kind::Historical;
    if (const Json* st = src.find("startStrideDays")) c.source.startStrideDays = toInt(st->str(), "startStrideDays");
  } else if (type == "bootstrap") {
    c.source.kind = SourceSpec::Kind::Bootstrap;
    c.source.paths = static_cast<std::uint64_t>(toInt(src.at("paths").str(), "paths"));
    if (const Json* b = src.find("meanBlockDays")) c.source.meanBlockDays = toDoubleText(b->str(), "meanBlockDays");
    if (const Json* sd = src.find("seed")) c.source.seed = static_cast<std::uint64_t>(toInt(sd->str(), "seed"));
  } else {
    throw std::runtime_error("config: source.type must be 'historical' or 'bootstrap'");
  }
  for (const std::string& h : src.at("horizonDays").strList()) c.source.horizonDays.push_back(toInt(h, "horizonDays"));
  for (int h : c.source.horizonDays) {
    if (h <= 0) throw std::runtime_error("config: horizonDays must be positive");
  }
  if (c.source.startStrideDays <= 0) throw std::runtime_error("config: startStrideDays must be positive");

  const Json& market = root.at("market");
  c.utilization = parseWadParam(market.at("utilization").str());
  if (c.utilization > refmodel::WAD) throw std::runtime_error("config: utilization must be <= 1");

  const Json& borrower = root.at("borrower");
  const Json* ethAmount = borrower.find("collateralEth");
  const Json* usdAmount = borrower.find("collateralUsd");
  if ((ethAmount == nullptr) == (usdAmount == nullptr)) {
    throw std::runtime_error("config: borrower needs exactly one of collateralEth or collateralUsd");
  }
  if (ethAmount != nullptr) c.collateralWei = parseDecimalScaled(ethAmount->str(), 18);
  if (usdAmount != nullptr) c.collateralUsd = parseDecimalScaled(usdAmount->str(), 18);
  if (c.collateralWei.isZero() && c.collateralUsd.isZero()) {
    throw std::runtime_error("config: the collateral amount must be positive");
  }
  c.ltvFractionText = borrower.at("ltvFractionOfMax").strList();
  for (const std::string& f : c.ltvFractionText) {
    const U256 v = parseWadParam(f);
    if (v.isZero() || v > refmodel::WAD) {
      throw std::runtime_error("config: ltvFractionOfMax must be in (0, 1], got '" + f + "'");
    }
    c.ltvFractions.push_back(v);
  }

  const Json& liq = root.at("liquidator");
  for (const std::string& h : liq.at("latencyHours").strList()) {
    const int hours = toInt(h, "latencyHours");
    if (hours < 0) throw std::runtime_error("config: latencyHours must be >= 0");
    c.latencyHours.push_back(hours);
  }
  c.minDebtUsd = U256(0);
  if (const Json* m = liq.find("minDebtUsd")) c.minDebtUsd = parseDecimalScaled(m->str(), 18);

  ProtocolParams defaultRate;
  bool haveDefaultRate = false;
  if (const Json* dr = root.find("defaultRate")) {
    readRate(*dr, defaultRate);
    haveDefaultRate = true;
  }
  for (const Json& v : root.at("variants").items) {
    Variant var;
    if (const Json* file = v.find("protocolFile")) {
      const Json doc = parseJson(readFile(resolve(baseDir, file->str())));
      var.params = parseProtocol(doc, haveDefaultRate ? &defaultRate : nullptr);
    } else {
      var.params = parseProtocol(v, haveDefaultRate ? &defaultRate : nullptr);
    }
    var.label = v.find("label") != nullptr ? v.at("label").str() : std::string("variant");
    try {
      validateProtocol(var.params);
    } catch (const refmodel::ModelError& e) {
      throw std::runtime_error("config: variant '" + var.label + "' is not a valid protocol deployment (" +
                               e.what() + ")");
    }
    c.variants.push_back(var);
  }
  if (c.variants.empty()) throw std::runtime_error("config: at least one variant is required");

  if (const Json* t = root.find("threads")) c.threads = static_cast<unsigned>(toInt(t->str(), "threads"));
  return c;
}

Config loadConfig(const std::string& path) {
  return parseConfig(parseJson(readFile(path)), dirOf(path));
}

}  // namespace sim
