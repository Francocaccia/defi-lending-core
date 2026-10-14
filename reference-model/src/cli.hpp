// Command-line contract (docs/M8_HANDOFF.md section 2):
//   refmodel <function> <arg1> <arg2> ...
// exit 0: stdout = "0x" + one 32-byte big-endian word per returned value + "\n"
// exit 1: the Solidity call would revert; stderr = "error: <reason>\n"
// exit 2: usage error;                    stderr = "usage: <reason>\n"
#pragma once

#include <ostream>
#include <string>
#include <vector>

namespace refmodel {

/// `args` excludes argv[0]. Writes ONLY to `out` / `err` and returns the exit code.
int run(const std::vector<std::string>& args, std::ostream& out, std::ostream& err);

}  // namespace refmodel
