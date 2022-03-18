# Copyright (C) 2022 Toitware ApS. All rights reserved.
# Use of this source code is governed by an MIT-style license that can be
# found in the package's LICENSE file.

set(FAILING_TESTS
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND FAILING_TESTS
    ${TEST_PREFIX}/tests/ar_test.toit
  )
endif()
