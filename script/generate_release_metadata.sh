#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-}"
if [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" != /* ]]; then
  echo "Usage: generate_release_metadata.sh /absolute/output/directory" >&2
  exit 2
fi

SOURCE_EPOCH="${SOURCE_DATE_EPOCH:-}"
if [[ ! "$SOURCE_EPOCH" =~ ^[0-9]+$ ]]; then
  echo "SOURCE_DATE_EPOCH must be set to a nonnegative integer" >&2
  exit 2
fi

REVISION="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"
if [[ ! "$REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Cannot resolve an immutable Git revision" >&2
  exit 1
fi
CREATED_AT="$(/bin/date -u -r "$SOURCE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
GRDB_VERSION="$(/usr/bin/jq -er '.pins[] | select(.identity == "grdb.swift") | .state.version' "$ROOT_DIR/Package.resolved")"
GRDB_REVISION="$(/usr/bin/jq -er '.pins[] | select(.identity == "grdb.swift") | .state.revision' "$ROOT_DIR/Package.resolved")"
GRDB_LOCATION="$(/usr/bin/jq -er '.pins[] | select(.identity == "grdb.swift") | .location' "$ROOT_DIR/Package.resolved")"
DIRTY=false
if [[ -n "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain=v1)" ]]; then
  DIRTY=true
fi

/bin/mkdir -p "$OUTPUT_DIR"
TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/guardian-release-json.XXXXXX")"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

/usr/bin/jq -n \
  --arg revision "$REVISION" \
  --arg created "$CREATED_AT" \
  --arg grdbVersion "$GRDB_VERSION" \
  --arg grdbRevision "$GRDB_REVISION" \
  --arg grdbLocation "$GRDB_LOCATION" \
  '{
    spdxVersion: "SPDX-2.3",
    dataLicense: "CC0-1.0",
    SPDXID: "SPDXRef-DOCUMENT",
    name: "CodexGuardian",
    documentNamespace: ("https://github.com/CodexGuardian/CodexGuardian/sbom/" + $revision),
    creationInfo: {
      created: $created,
      creators: ["Tool: CodexGuardian-release-metadata-v1"]
    },
    packages: [
      {
        name: "CodexGuardian",
        SPDXID: "SPDXRef-Package-CodexGuardian",
        versionInfo: $revision,
        downloadLocation: "NOASSERTION",
        filesAnalyzed: false,
        licenseConcluded: "NOASSERTION",
        licenseDeclared: "LicenseRef-PolyForm-Noncommercial-1.0.0",
        copyrightText: "NOASSERTION"
      },
      {
        name: "GRDB.swift",
        SPDXID: "SPDXRef-Package-GRDB",
        versionInfo: $grdbVersion,
        downloadLocation: $grdbLocation,
        filesAnalyzed: false,
        licenseConcluded: "MIT",
        licenseDeclared: "MIT",
        copyrightText: "NOASSERTION",
        externalRefs: [{
          referenceCategory: "PACKAGE-MANAGER",
          referenceType: "purl",
          referenceLocator: ("pkg:github/groue/GRDB.swift@" + $grdbVersion)
        }],
        checksums: [{ algorithm: "SHA1", checksumValue: $grdbRevision }]
      }
    ],
    relationships: [{
      spdxElementId: "SPDXRef-Package-CodexGuardian",
      relationshipType: "DEPENDS_ON",
      relatedSpdxElement: "SPDXRef-Package-GRDB"
    }]
  }' > "$TMP_DIR/codexguardian.spdx.json"

/usr/bin/jq -n \
  --arg revision "$REVISION" \
  --arg created "$CREATED_AT" \
  --arg grdbRevision "$GRDB_REVISION" \
  --arg grdbLocation "$GRDB_LOCATION" \
  --argjson dirty "$DIRTY" \
  '{
    _type: "https://in-toto.io/Statement/v1",
    subject: [{ name: "CodexGuardian", digest: { gitCommit: $revision } }],
    _predicateType: "https://slsa.dev/provenance/v1",
    predicate: {
      buildDefinition: {
        buildType: "https://codexguardian.local/build-types/swiftpm-macos-v1",
        externalParameters: {
          sourceRevision: $revision,
          sourceTreeDirty: $dirty
        },
        internalParameters: {},
        resolvedDependencies: [{
          uri: $grdbLocation,
          digest: { gitCommit: $grdbRevision }
        }]
      },
      runDetails: {
        builder: { id: "https://codexguardian.local/builders/local-release-v1" },
        metadata: {
          invocationId: ("guardian-release-" + $revision),
          startedOn: $created,
          finishedOn: $created
        }
      }
    }
  }' > "$TMP_DIR/codexguardian.provenance.json"

/usr/bin/jq -e . "$TMP_DIR/codexguardian.spdx.json" >/dev/null
/usr/bin/jq -e . "$TMP_DIR/codexguardian.provenance.json" >/dev/null
/bin/chmod 644 "$TMP_DIR/codexguardian.spdx.json" "$TMP_DIR/codexguardian.provenance.json"
/bin/mv -f "$TMP_DIR/codexguardian.spdx.json" "$OUTPUT_DIR/codexguardian.spdx.json"
/bin/mv -f "$TMP_DIR/codexguardian.provenance.json" "$OUTPUT_DIR/codexguardian.provenance.json"

echo "Release metadata written to $OUTPUT_DIR"
