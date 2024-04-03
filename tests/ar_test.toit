// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/TESTS_LICENSE file.

import expect show *
import ar show *
import host.directory
import host.file
import host.pipe
import io
import system

TESTS ::= [
  {:},
  {"odd": "odd".to-byte-array},
  {"even": "even".to-byte-array},
  {
    "even": "even".to-byte-array,
    "odd": "odd".to-byte-array,
  },
  {
    "odd": "odd".to-byte-array,
    "even": "even".to-byte-array,
  },
  {
    "binary": #[0, 1, 2, 255],
    "newlines": "\n\n\n\n".to-byte-array,
    "newlines2": "\a\a\a\a\a".to-byte-array,
    "big": ("the quick brown fox jumps over the lazy dog" * 1000).to-byte-array
  },
]

write-ar file-mapping/Map --add-with-ar-file/bool=false:
  writer := io.Buffer
  ar-writer := ArWriter writer
  file-mapping.do: |name content|
    if add-with-ar-file:
      ar-writer.add
          ArFile name content
    else:
      ar-writer.add name content
  return writer.bytes

run-test file-mapping/Map tmp-dir [generate-ar]:
  ba := generate-ar.call tmp-dir file-mapping

  seen := {}
  count := 0
  ar-reader := ArReader (io.Reader ba)
  ar-reader.do: |file/ArFile|
    count++
    seen.add file.name
    expected := file-mapping[file.name]
    expect-equals expected file.content
  // No file was seen twice.
  expect-equals seen.size count
  expect-equals file-mapping.size count

  seen = {}
  count = 0
  ar-reader = ArReader.from-bytes ba
  ar-reader.do --offsets: |file-offsets/ArFileOffsets|
    count++
    seen.add file-offsets.name
    expected := file-mapping[file-offsets.name]
    actual := ba.copy file-offsets.from file-offsets.to
    expect-equals expected actual
  // No file was seen twice.
  expect-equals seen.size count
  expect-equals file-mapping.size count

  ar-reader = ArReader (io.Reader ba)
  // We should find all files if we advance from top to bottom.
  last-name := null
  file-mapping.do: |name content|
    last-name = name
    file := ar-reader.find name
    expect-equals content file.content

  ar-reader = ArReader.from-bytes ba
  // We should find all files if we advance from top to bottom.
  file-mapping.do: |name content|
    last-name = name
    file-offsets := ar-reader.find --offsets name
    actual := ba.copy file-offsets.from file-offsets.to
    expect-equals content actual

  ar-reader = ArReader (io.Reader ba)
  ar-file := ar-reader.find "not there"
  expect-null ar-file
  if last-name:
    ar-file = ar-reader.find last-name
    // We skipped over all files, so can't find anything anymore.
    expect-null ar-file

  if last-name:
    ar-reader = ArReader.from-bytes ba
    file := ar-reader.find last-name
    expect-not-null file
    // But now we can't find the same file anymore.
    file = ar-reader.find last-name
    expect-null file
    // In fact we can't find any file anymore:
    file-mapping.do: |name content|
      file = ar-reader.find name
      expect-null file

  // FreeRTOS doesn't have `ar`.
  if system.platform == "FreeRTOS": return

  test-path := "$tmp-dir/test.a"
  stream := file.Stream.for-write test-path
  stream.out.write ba
  stream.close
  file-mapping.do: |name expected-content|
    actual := extract test-path name
    expect-equals expected-content actual

extract archive-file contained-file -> ByteArray:
  // 'p' prints the $contained_file onto stdout.
  from := pipe.from "ar" "p" archive-file contained-file
  result := ByteArray 0
  reader := from.in
  while next := reader.read:
    result += next
  from.close
  return result

run-tests [generate-ar]:
  tmp-dir := directory.mkdtemp "/tmp/ar_test"
  try:
    TESTS.do: run-test it tmp-dir generate-ar
  finally:
    directory.rmdir --recursive tmp-dir

main:
  run-tests: |tmp-dir file-mapping| write-ar file-mapping
  run-tests: |tmp-dir file-mapping| write-ar file-mapping --add-with-ar-file
