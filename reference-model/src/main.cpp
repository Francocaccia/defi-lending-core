#include <iostream>
#include <string>
#include <vector>

#include "cli.hpp"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

int main(int argc, char** argv) {
#ifdef _WIN32
  // The output contract is "...\n" exactly; stop the CRT from turning it into "\r\n".
  _setmode(_fileno(stdout), _O_BINARY);
  _setmode(_fileno(stderr), _O_BINARY);
#endif
  std::vector<std::string> args;
  for (int i = 1; i < argc; ++i) args.emplace_back(argv[i]);
  const int code = refmodel::run(args, std::cout, std::cerr);
  std::cout.flush();
  return code;
}
