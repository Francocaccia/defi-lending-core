# Black-box check of the refmodel binary.
# Inputs: BIN, EXPECT_CODE, EXPECT_OUT (exact stdout WITHOUT the final newline; empty = no stdout),
#         EXPECT_ERR_PREFIX (stderr must start with it; empty = stderr must be empty), ARGS (comma list).
string(REPLACE "," ";" ARG_LIST "${ARGS}")
execute_process(
  COMMAND ${BIN} ${ARG_LIST}
  RESULT_VARIABLE rc
  OUTPUT_VARIABLE out
  ERROR_VARIABLE err)

if(NOT "${rc}" STREQUAL "${EXPECT_CODE}")
  message(FATAL_ERROR "exit code: expected ${EXPECT_CODE}, got ${rc}\nstdout: ${out}\nstderr: ${err}")
endif()

if("${EXPECT_OUT}" STREQUAL "")
  set(want_out "")
else()
  # exactly one line ending in a bare LF (no CR)
  set(want_out "${EXPECT_OUT}\n")
endif()
if(NOT "${out}" STREQUAL "${want_out}")
  message(FATAL_ERROR "stdout mismatch:\nexpected: [${want_out}]\n     got: [${out}]")
endif()

if("${EXPECT_ERR_PREFIX}" STREQUAL "")
  if(NOT "${err}" STREQUAL "")
    message(FATAL_ERROR "stderr should be empty, got: [${err}]")
  endif()
else()
  string(FIND "${err}" "${EXPECT_ERR_PREFIX}" pos)
  if(NOT pos EQUAL 0)
    message(FATAL_ERROR "stderr should start with [${EXPECT_ERR_PREFIX}], got: [${err}]")
  endif()
endif()
