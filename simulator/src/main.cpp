// defi_sim: Monte Carlo / historical risk simulator for the lending protocol.
//
//   defi_sim run <config.json> [--out <dir>] [--threads N] [--quiet]
//
// Reads the experiment (protocol parameters with the contracts' own names, price data, borrower and
// liquidator assumptions), runs every variant on every path, prints a Markdown report and, with
// --out, writes <dir>/<name>.md and <dir>/<name>.csv.
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>

#include "config.hpp"
#include "data.hpp"
#include "report.hpp"
#include "runner.hpp"

namespace {

struct StderrProgress : sim::Progress {
  void note(const std::string& message) override { std::fprintf(stderr, "[defi_sim] %s\n", message.c_str()); }
};

int usage() {
  std::fprintf(stderr, "usage: defi_sim run <config.json> [--out <dir>] [--threads N] [--quiet]\n");
  return 2;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3 || std::string(argv[1]) != "run") return usage();
  const std::string configPath = argv[2];
  std::string outDir;
  unsigned threadsOverride = 0;
  bool quiet = false;
  for (int i = 3; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--out" && i + 1 < argc) outDir = argv[++i];
    else if (a == "--threads" && i + 1 < argc) threadsOverride = static_cast<unsigned>(std::atoi(argv[++i]));
    else if (a == "--quiet") quiet = true;
    else return usage();
  }

  try {
    sim::Config cfg = sim::loadConfig(configPath);
    if (threadsOverride != 0) cfg.threads = threadsOverride;

    auto eth = sim::loadOracleCsv(cfg.ethCsv);
    auto usdc = sim::loadOracleCsv(cfg.usdcCsv);
    if (cfg.fromUnix != 0) {
      eth = sim::fromTime(eth, cfg.fromUnix);
      usdc = sim::fromTime(usdc, cfg.fromUnix);
    }
    const sim::Grid grid = sim::buildGrid(eth, usdc, cfg.stepSeconds);

    StderrProgress progress;
    const std::vector<sim::Row> rows = sim::runExperiment(cfg, grid, quiet ? nullptr : &progress);
    const std::string md = sim::renderMarkdown(cfg, grid, rows);
    std::fputs(md.c_str(), stdout);

    if (!outDir.empty()) {
      std::ofstream(outDir + "/" + cfg.name + ".md", std::ios::binary) << md;
      std::ofstream(outDir + "/" + cfg.name + ".csv", std::ios::binary) << sim::renderCsv(rows);
    }
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "error: %s\n", e.what());
    return 1;
  }
}
