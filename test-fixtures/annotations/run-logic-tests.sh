#!/bin/bash
# Runs the WS4 pure-logic tests WITHOUT Xcode (Command Line Tools are enough).
# It derives a plain executable from leanring-buddyTests/AnnotationTests.swift
# (Swift Testing's #expect/@Test are rewritten to a tiny shim), compiles it with the
# pure model/mapper files, then also decodes every fixture in this directory.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch_directory="${TMPDIR:-/tmp}/clicky-ws4-logic-tests"
rm -rf "$scratch_directory" && mkdir -p "$scratch_directory"

test_source="$repository_root/leanring-buddyTests/AnnotationTests.swift"
derived_tests="$scratch_directory/DerivedAnnotationTests.swift"

# Rewrite Swift Testing syntax into plain functions + a check() shim.
sed -E \
  -e '/^import Testing/d' \
  -e '/^@testable import/d' \
  -e 's/#expect\(/check(/g' \
  -e 's/^    @Test func /    func /' \
  "$test_source" > "$derived_tests"

test_names="$(grep -E '^    @Test func ' "$test_source" | sed -E 's/.*func ([A-Za-z0-9_]+)\(\).*/\1/')"

{
  echo 'import Foundation'
  echo 'import CoreGraphics'
  echo 'var failureCount = 0'
  echo 'func check(_ condition: Bool, line: Int = #line) { if !condition { failureCount += 1; print("  FAIL at derived line \(line)") } }'
  echo 'func runFixtureChecks(fixtureDirectory: String) {'
  echo '  struct Fixture: Decodable { let shapes: [AnnotationShape]; let image_width_px: Int; let image_height_px: Int }'
  echo '  let names = (try? FileManager.default.contentsOfDirectory(atPath: fixtureDirectory))?.filter { $0.hasSuffix(".json") }.sorted() ?? []'
  echo '  check(names.count >= 5)'
  echo '  for name in names {'
  echo '    guard let data = FileManager.default.contents(atPath: fixtureDirectory + "/" + name),'
  echo '          let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else { print("  FAIL decode \(name)"); failureCount += 1; continue }'
  echo '    let mapper = AnnotationCoordinateMapper(displayFrameInAppKitGlobalPoints: CGRect(x: 0, y: 0, width: 1512, height: 982), imageWidthInPixels: Double(fixture.image_width_px), imageHeightInPixels: Double(fixture.image_height_px))'
  echo '    let mapped = mapper.mappedShapes(from: fixture.shapes)'
  echo '    print("fixture \(name): \(fixture.shapes.count) shapes decoded, \(mapped.count) mapped")'
  echo '  }'
  echo '}'
  echo 'let suite = AnnotationTests()'
  for test_name in $test_names; do
    echo "print(\"RUN $test_name\"); do { try suite.$test_name() } catch { print(\"  THREW \\(error)\"); failureCount += 1 }"
  done
  echo "runFixtureChecks(fixtureDirectory: \"$repository_root/test-fixtures/annotations\")"
  echo 'print(failureCount == 0 ? "ALL PASSED" : "\(failureCount) FAILURE(S)")'
  echo 'exit(failureCount == 0 ? 0 : 1)'
} > "$scratch_directory/main.swift"

# `try` on non-throwing calls is only a warning; silence it.
xcrun swiftc -o "$scratch_directory/run" -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.2 \
  -suppress-warnings \
  "$repository_root/leanring-buddy/AnnotationShape.swift" \
  "$repository_root/leanring-buddy/AnnotationCoordinateMapper.swift" \
  "$derived_tests" "$scratch_directory/main.swift"

"$scratch_directory/run"
