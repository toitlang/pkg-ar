// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

import bytes
import io
import reader show Reader

/**
A library for reading and writing 'ar' archives.
*/

AR-HEADER_ ::= "!<arch>\x0A"

FILE-NAME-OFFSET_ ::= 0
FILE-TIMESTAMP-OFFSET_ ::= 16
FILE-OWNER-ID-OFFSET_ ::= 28
FILE-GROUP-ID-OFFSET_ ::= 34
FILE-MODE-OFFSET_ ::= 40
FILE-BYTE-SIZE-OFFSET_ ::= 48
FILE-ENDING-CHARS-OFFSET_ ::= 58
FILE-HEADER-SIZE_ ::= 60

FILE-ENDING-CHARS_ ::= "\x60\x0A"

FILE-NAME-SIZE_ ::= FILE-TIMESTAMP-OFFSET_ - FILE-NAME-OFFSET_
FILE-TIMESTAMP-SIZE_ ::= FILE-OWNER-ID-OFFSET_ - FILE-TIMESTAMP-OFFSET_
FILE-OWNER-ID-SIZE_ ::= FILE-GROUP-ID-OFFSET_ - FILE-OWNER-ID-OFFSET_
FILE-GROUP-ID-SIZE_ ::= FILE-MODE-OFFSET_ - FILE-GROUP-ID-OFFSET_
FILE-MODE-SIZE_ ::= FILE-BYTE-SIZE-OFFSET_ - FILE-MODE-OFFSET_
FILE-BYTE-SIZE-SIZE_ ::= FILE-ENDING-CHARS-OFFSET_ - FILE-BYTE-SIZE-OFFSET_
FILE-ENDING-CHARS-SIZE_ ::= FILE-HEADER-SIZE_ - FILE-ENDING-CHARS-OFFSET_

PADDING-STRING_ ::= "\x0A"
PADDING-CHAR_ ::= '\x0A'

DETERMINISTIC-TIMESTAMP_ ::= 0
DETERMINISTIC-OWNER-ID_  ::= 0
DETERMINISTIC-GROUP-ID_  ::= 0
DETERMINISTIC-MODE_      ::= 0b110_100_100  // Octal 644.

/**
Whether the given $bytes start with an AR header.
*/
has-valid-ar-header bytes/ByteArray -> bool:
  return bytes.size >= AR-HEADER_.size and bytes[..AR-HEADER_.size] == AR-HEADER_.to-byte-array

/**
An 'ar' archiver.

Writes the given files into the writer in the 'ar' file format.
*/
class ArWriter:
  writer_/io.Writer ::= ?

  /**
  Takes an $io.Writer as argument.

  For compatibility reasons, also accepts an "old-style" writer. This is
    deprecated and will be removed in the future.
  */
  constructor writer:
    if writer is io.Writer:
      writer_ = writer
    else:
      writer_ = io.Writer.adapt writer
    write-ar-header_

  /**
  Adds a new "file" to the ar-archive.

  This function sets all file attributes to the same default values as are used
    by 'ar' when using the 'D' (deterministic) option. For example, the
    modification date is set to 0 (epoch time).
  */
  add name/string contents/io.Data -> none:
    if name.size > FILE-NAME-SIZE_: throw "Filename too long"
    write-ar-file-header_ name contents.byte-size
    writer_.write contents
    if needs-padding_ contents.byte-size:
      writer_.write PADDING-STRING_

  /**
  Variant of $(add name contents).
  Adds a new $ar-file to the ar-archive.
  */
  add ar-file/ArFile -> none:
    add ar-file.name ar-file.contents

  write-ar-header_:
    writer_.write AR-HEADER_

  write-string_ str/string header/ByteArray offset/int size/int:
    for i := 0; i < size; i++:
      if i < str.size:
        header[offset + i] = str.at --raw i
      else:
        header[offset + i] = ' '

  write-number_ --base/int n/int header/ByteArray offset/int size/int:
    // For simplicity we write the number right to left and then shift
    // the computed values.
    i := size - 1
    for ; i >= 0; i--:
      header[offset + i] = '0' + n % base
      n = n / base
      if n == 0: break
    if n != 0: throw "OUT_OF_RANGE"
    // 'i' is the last entry where we wrote a significant digit.
    nb-digits := size - i
    number-offset := i
    header.replace offset header (offset + number-offset) (offset + size)
    // Pad the rest with spaces.
    for j := nb-digits; j < size; j++:
      header[offset + j] = ' '

  write-decimal_ n/int header/ByteArray offset/int size/int:
    write-number_ --base=10 n header offset size

  write-octal_ n/int header/ByteArray offset/int size/int:
    write-number_ --base=8 n header offset size

  write-ar-file-header_ name/string contents-size/int:
    header := ByteArray FILE-HEADER-SIZE_
    write-string_ name
        header
        FILE-NAME-OFFSET_
        FILE-NAME-SIZE_
    write-decimal_ DETERMINISTIC-TIMESTAMP_
        header
        FILE-TIMESTAMP-OFFSET_
        FILE-TIMESTAMP-SIZE_
    write-decimal_ DETERMINISTIC-OWNER-ID_
        header
        FILE-OWNER-ID-OFFSET_
        FILE-OWNER-ID-SIZE_
    write-decimal_ DETERMINISTIC-GROUP-ID_
        header
        FILE-GROUP-ID-OFFSET_
        FILE-GROUP-ID-SIZE_
    write-octal_ DETERMINISTIC-MODE_
        header
        FILE-MODE-OFFSET_
        FILE-MODE-SIZE_
    write-decimal_ contents-size
        header
        FILE-BYTE-SIZE-OFFSET_
        FILE-BYTE-SIZE-SIZE_
    write-string_ FILE-ENDING-CHARS_
        header
        FILE-ENDING-CHARS-OFFSET_
        FILE-ENDING-CHARS-SIZE_

    writer_.write header

  needs-padding_ size/int -> bool:
    return size & 1 == 1

class ArFile:
  name / string
  contents / ByteArray

  constructor .name .contents:

  /** Deprecated. Use $contents instead. */
  content -> ByteArray:
    return contents

class ArFileOffsets:
  name / string
  from / int
  to   / int

  constructor .name .from .to:

class ArReader:
  reader_ / io.Reader
  offset_ / int := 0

  constructor reader/Reader:
    if reader is io.Reader:
      reader_ = reader as io.Reader
    else:
      reader_ = io.Reader.adapt reader
    skip-header_

  constructor.from-bytes buffer/ByteArray:
    return ArReader (io.Reader buffer)

  /// Returns the next file in the archive.
  /// Returns null if none is left.
  next -> ArFile?:
    name := read-name_
    if not name: return null
    byte-size := read-byte-size-skip-ignored-header_
    contents := read-contents_ byte-size
    return ArFile name contents

  /**
  Returns the next $ArFileOffsets, or `null` if no file is left.
  */
  next --offsets/bool -> ArFileOffsets?:
    if not offsets: throw "INVALID_ARGUMENT"
    name := read-name_
    if not name: return null
    byte-size := read-byte-size-skip-ignored-header_
    contents-offset := offset_
    skip-contents_ byte-size
    return ArFileOffsets name contents-offset (contents-offset + byte-size)

  /// Invokes the given $block on each $ArFile of the archive.
  do [block]:
    while file := next:
      block.call file

  /// Invokes the given $block on each $ArFileOffsets of the archive.
  do --offsets/bool [block]:
    if not offsets: throw "INVALID_ARGUMENT"
    while file-offsets := next --offsets:
      block.call file-offsets

  /**
  Finds the given $name file in the archive.
  Returns null if not found.
  This operation does *not* reset the archive. If files were skipped to
    find the given $name, then these files can't be read without creating
    a new $ArReader.
  */
  find name/string -> ArFile?:
    while true:
      file-name := read-name_
      if not file-name: return null
      byte-size := read-byte-size-skip-ignored-header_
      if file-name == name:
        contents := read-contents_ byte-size
        return ArFile name contents
      skip-contents_ byte-size

  /**
  Finds the given $name file in the archive.
  Returns null if not found.
  This operation does *not* reset the archive. If files were skipped to
    find the given $name, then these files can't be read without creating
    a new $ArReader.
  */
  find --offsets/bool name/string -> ArFileOffsets?:
    if not offsets: throw "INVALID_ARGUMENT"
    while true:
      file-name := read-name_
      if not file-name: return null
      byte-size := read-byte-size-skip-ignored-header_
      if file-name == name:
        file-offset := offset_
        skip-contents_ byte-size
        return ArFileOffsets name file-offset (file-offset + byte-size)
      skip-contents_ byte-size

  skip-header_:
    header := reader-read-string_ AR-HEADER_.size
    if header != AR-HEADER_: throw "Invalid Ar File"

  read-decimal_ size/int -> int:
    str := reader-read-string_ size
    result := 0
    for i := 0; i < str.size; i++:
      c := str[i]
      if c == ' ': return result
      else if '0' <= c <= '9': result = 10 * result + c - '0'
      else: throw "INVALID_AR_FORMAT"
    return result

  is-padded_ size/int: return size & 1 == 1

  read-name_ -> string?:
    if not reader_.try-ensure-buffered 1: return null
    name / string := reader-read-string_ FILE-NAME-SIZE_
    name = name.trim --right
    if name.ends-with "/": name = name.trim --right "/"
    return name

  read-byte-size-skip-ignored-header_ -> int:
    skip-count := FILE-TIMESTAMP-SIZE_
        + FILE-OWNER-ID-SIZE_
        + FILE-GROUP-ID-SIZE_
        + FILE-MODE-SIZE_
    reader-skip_ skip-count
    byte-size := read-decimal_ FILE-BYTE-SIZE-SIZE_
    ending-char1 := reader-read-byte_
    ending-char2 := reader-read-byte_
    if ending-char1 != FILE-ENDING-CHARS_[0] or ending-char2 != FILE-ENDING-CHARS_[1]:
      throw "INVALID_AR_FORMAT"
    return byte-size

  read-contents_ byte-size/int -> ByteArray:
    contents := reader-read-bytes_ byte-size
    if is-padded_ byte-size: reader-skip_ 1
    return contents

  skip-contents_ byte-size/int -> none:
    reader-skip_ byte-size
    if is-padded_ byte-size: reader-skip_ 1

  reader-read-string_ size/int -> string:
    result := reader_.read-string size
    offset_ += size
    return result

  reader-skip_ size/int -> none:
    reader_.skip size
    offset_ += size

  reader-read-byte_ -> int:
    result := reader_.read-byte
    offset_++
    return result

  reader-read-bytes_ size/int -> ByteArray:
    result := reader_.read-bytes size
    offset_ += size
    return result
